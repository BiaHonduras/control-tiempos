const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const base=path.resolve(__dirname,'..');
function setup(repo,worker,{offline=false}={}){
 const events={},saved=new Map(),deleted=[];let release;const gate=new Promise(r=>release=r);
 const scope='https://example.test/'+repo+'/';
 const cache={match:async req=>saved.get(typeof req==='string'?req:req.url),put:async(req,res)=>saved.set(typeof req==='string'?req:req.url,res),addAll:async()=>{}};
 const self={location:new URL(scope+worker),registration:{scope},clients:{claim:async()=>{}},skipWaiting:async()=>{},addEventListener:(name,fn)=>events[name]=fn};
 const caches={open:async()=>{await gate;return cache},keys:async()=>['bia-control-v-old','bia-control-static-v-old','other-app'],delete:async k=>deleted.push(k)};
 const ctx={self,caches,URL,Response,fetch:async()=>{if(offline)throw Error('offline');return new Response('asset body')}};
 vm.runInNewContext(fs.readFileSync(path.join(base,worker),'utf8'),ctx);
 function fire(url,mode='cors',method='GET'){let result;const pending=[];events.fetch({request:{url,method,mode},respondWith:p=>result=p,waitUntil:p=>pending.push(p)});return {get result(){return result},pending};}
 return {events,saved,deleted,release,fire,scope};
}
const repo=path.basename(base),worker=repo==='contenedores'?'sw.js':'service-worker.js';
test('clone before consumption while cache.open is delayed; no unhandled cache race',async()=>{
 const s=setup(repo,worker),r=s.fire(s.scope+'index.html','navigate');
 const response=await r.result;assert.equal(await response.text(),'asset body');
 s.release();await Promise.all(r.pending);assert.equal(await s.saved.get(s.scope+'index.html').text(),'asset body');
 const asset=s.fire(s.scope+'asset.js');const body=await asset.result;assert.equal(await body.text(),'asset body');await Promise.all(asset.pending);assert.equal(await s.saved.get(s.scope+'asset.js').text(),'asset body');
});
test('external APIs, other apps and writes bypass this worker; activation preserves their caches',async()=>{
 const s=setup(repo,worker);s.release();
 for(const url of ['https://cdn.jsdelivr.net/example.js','https://x.supabase.co/rest/v1/usuarios','https://example.test/another-app/app.js'])assert.equal(s.fire(url).result,undefined);
 assert.equal(s.fire(s.scope+'app.js','cors','POST').result,undefined);
 let done;s.events.activate({waitUntil:p=>done=p});await done;
 assert.deepEqual(s.deleted,[repo==='contenedores'?'bia-control-static-v-old':'bia-control-v-old']);
});
test('navigation keeps exact URL; offline fallback never turns login into cached index',async()=>{
 const s=setup(repo,worker);const r=s.fire(s.scope+'login.html?next=1','navigate');await r.result;s.release();await Promise.all(r.pending);
 assert(s.saved.has(s.scope+'login.html?next=1'));assert(!s.saved.has(s.scope+'index.html'));
 const off=setup(repo,worker,{offline:true});off.saved.set(repo==='contenedores'?'./login.html':'./offline.html',new Response('safe fallback'));off.release();assert.equal(await (await off.fire(off.scope+'unknown.html','navigate').result).text(),'safe fallback');
});
