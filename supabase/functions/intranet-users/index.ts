import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.95.0';
const cors={'Access-Control-Allow-Origin':'https://biahonduras.github.io','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const response=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store'}});
const password=()=>{const bytes=crypto.getRandomValues(new Uint8Array(24));return 'Bia!'+Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('')+'aA9!'};
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});if(req.method!=='POST')return response({error:'METODO_NO_PERMITIDO'},405);
 try{
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const body=await req.json();
 const call=async(name:string,args:any)=>{const {data,error}=await admin.rpc(name,args);if(error)throw Error(error.message);return data};
 const findUser=async(email:string)=>{for(let page=1;;page++){const {data,error}=await admin.auth.admin.listUsers({page,perPage:1000});if(error)throw error;const user=data.users.find(u=>u.email?.toLowerCase()===email);if(user)return user;if(data.users.length<1000)return null}};
 // One-use, expiring bootstrap capability. Payload is stored privately by the deployment administrator.
 // Public browser roles cannot claim it or choose its accounts/roles. No bootstrap secret is stored here.
 if(body.action==='bootstrap'){
  if(typeof body.token!=='string'||body.token.length!==64)return response({error:'BOOTSTRAP_NO_AUTORIZADO'},403);
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(body.token))),b=>b.toString(16).padStart(2,'0')).join('');
  const plan=await call('bia_bootstrap_claim',{p_hash:digest});const results=[];
  for(const item of plan){let user=await findUser(item.email.toLowerCase());let initial_password=null;let created=false;
   if(!user){initial_password=password();const {data,error}=await admin.auth.admin.createUser({email:item.email,password:initial_password,email_confirm:true,user_metadata:{nombre:item.nombre_corto},app_metadata:{must_change_password:true}});if(error||!data.user)throw error||Error('NO_SE_PUDO_CREAR');user=data.user;created=true}
   const {error:enableError}=await admin.auth.admin.updateUserById(user.id,{ban_duration:'none'});if(enableError)throw enableError;await call('bia_bootstrap_assign',{p_target:user.id,p_data:item});results.push({email:item.email,created,initial_password});
  }return response({ok:true,results});
 }
 const token=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');const {data:session,error:authError}=await admin.auth.getUser(token);
 if(authError||!session.user)return response({error:'AUTH_REQUIRED'},401);const actor=session.user.id;
 const action=String(body.action||''),target=body.user_id||null,data=body.data||{};
 await call('bia_directory_check',{p_actor:actor,p_action:action,p_target:action==='create'?null:target,p_data:data});
 if(action==='create'){
  const email=String(data.email||'').trim().toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))return response({error:'CORREO_INVALIDO'},400);
  let user=await findUser(email),initial_password=null,created=false;
  if(!user){initial_password=password();const {data:createdUser,error}=await admin.auth.admin.createUser({email,password:initial_password,email_confirm:true,user_metadata:{nombre:data.nombre_corto},app_metadata:{must_change_password:true}});if(error||!createdUser.user)throw error||Error('NO_SE_PUDO_CREAR');user=createdUser.user;created=true}
  await call('bia_directory_create',{p_actor:actor,p_target:user.id,p_data:data});return response({ok:true,created,initial_password});
 }
 if(!target)return response({error:'USUARIO_INVALIDO'},400);
 const {data:targetAuth,error:lookupError}=await admin.auth.admin.getUserById(target);if(lookupError||!targetAuth.user)throw Error('USUARIO_NO_ENCONTRADO');
 const apply=()=>call('bia_directory_apply',{p_actor:actor,p_target:target,p_action:action,p_data:data,p_version:body.version});
 if(action==='reset'){
  await apply();const initial_password=password();const {error}=await admin.auth.admin.updateUserById(target,{password:initial_password,app_metadata:{...targetAuth.user.app_metadata,must_change_password:true}});if(error)throw error;return response({ok:true,initial_password});
 }
 if(action==='restore'||action==='toggle'&&data.active===true){const {error}=await admin.auth.admin.updateUserById(target,{ban_duration:'none'});if(error)throw error;await apply();}
 else {await apply();if(action==='delete'||action==='toggle'&&data.active===false){const {error}=await admin.auth.admin.updateUserById(target,{ban_duration:'876000h'});if(error)throw error;}}
 return response({ok:true});
 }catch(error){return response({error:error instanceof Error?error.message:'OPERACION_NO_COMPLETADA'},400)}
});
