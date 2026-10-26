import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../cambiar-password.html',import.meta.url),'utf8');
const script=html.match(/<script type="module">([\s\S]*?)<\/script>/)[1].replace(/^import .*;\n/gm,'');
async function setup({validSession=true,saveError=null,logoutThrows=false}={}){
 const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{value:'Fixture!123Ab',textContent:'',disabled:false});return nodes.get(id);};
 const calls={save:0,refresh:0,logout:0,redirect:null};
 const context={document:{getElementById:node},location:{replace:path=>calls.redirect=path},supabase:{auth:{getUser:async()=>({data:{user:validSession?{id:'self'}:null},error:validSession?null:new Error('Auth session missing!')}),refreshSession:async()=>{calls.refresh++;throw Error('Invalid Refresh Token')},signOut:async options=>{calls.logout++;assert.equal(options.scope,'local');if(logoutThrows)throw Error('Auth session missing!');return {error:new Error('Session already revoked')};}},functions:{invoke:async(name,options)=>{calls.save++;assert.equal(name,'admin-users');assert.equal(options.body.action,'change_own_password');assert(!('user_id' in options.body));return saveError?{error:saveError}:{data:{ok:true},error:null};}}}};
 vm.createContext(context);await vm.runInContext('(async()=>{'+script+'})()',context);return {node,calls,submit:()=>node('changeForm').onsubmit({preventDefault(){}})};
}
test('saved password redirects to login without refreshing a session revoked by Auth',async()=>{for(const logoutThrows of [false,true]){const t=await setup({logoutThrows});await t.submit();assert.equal(t.calls.save,1);assert.equal(t.calls.refresh,0);assert.equal(t.calls.logout,1);assert.equal(t.calls.redirect,'./intranet.html');assert.equal(t.node('newPassword').value,'');assert.equal(t.node('confirmPassword').value,'');assert.match(t.node('mensaje').textContent,/Contraseña actualizada/);}});
test('missing initial session cannot submit a password change',async()=>{const t=await setup({validSession:false});await t.submit();assert.equal(t.calls.save,0);assert.equal(t.calls.redirect,'./intranet.html');assert.equal(t.node('savePassword').disabled,true);});
test('failed save remains a failure and expired sessions have a useful Spanish message',async()=>{const t=await setup({saveError:{message:'Auth session missing!'}});await t.submit();assert.equal(t.calls.redirect,null);assert.equal(t.calls.logout,0);assert.equal(t.node('savePassword').disabled,false);assert.match(t.node('mensaje').textContent,/La sesión venció/);assert.doesNotMatch(t.node('mensaje').textContent,/actualizada/);});
test('mismatched passwords never reach the password endpoint',async()=>{const t=await setup();t.node('confirmPassword').value='Different!123';await t.submit();assert.equal(t.calls.save,0);assert.match(t.node('mensaje').textContent,/no coinciden/);});
