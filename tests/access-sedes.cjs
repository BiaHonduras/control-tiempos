const {PGlite}=require('@electric-sql/pglite');const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
(async()=>{const db=new PGlite();await db.exec(`
create role authenticated;create role anon;create schema auth;create schema devoluciones_privado;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}',raw_app_meta_data jsonb default '{}',created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table usuarios_sedes(user_id uuid,sede text,rol text,nombre text,activo boolean,puede_cierre_dia boolean default false,updated_at timestamptz default now());
create table usuarios(id serial,auth_user_id uuid,nombre_corto text,usuario text,activo boolean);
create table devoluciones(id uuid,sede text,version int,estado text,eliminado_at timestamptz);
create table supplier_claims(id serial,agency text,created_by uuid);alter table supplier_claims enable row level security;
create policy "Operadores actualizan reclamos" on supplier_claims for update using(false) with check(false);
create policy "Operadores crean reclamos" on supplier_claims for insert with check(false);
create policy read_claims on supplier_claims for select using(public.usuario_puede_sede(agency));
` .replace('create policy read_claims on supplier_claims for select using(public.usuario_puede_sede(agency));',''));
await db.exec(`create function usuario_password_actualizada() returns boolean language sql stable security definer as $$select exists(select 1 from auth.users where id=auth.uid() and coalesce(raw_app_meta_data->>'must_change_password','false')<>'true')$$;
create function usuario_es_maestro() returns boolean language sql stable security definer as $$select false$$;
create function devoluciones_privado.autorizado() returns boolean language sql stable security definer as $$select exists(select 1 from public.usuarios where auth_user_id=auth.uid() and activo)$$;
grant usage on schema public,auth,devoluciones_privado to authenticated,anon;grant select,insert,update on supplier_claims to authenticated;grant usage on sequence supplier_claims_id_seq to authenticated;grant select on usuarios_sedes to authenticated;
`);
const migration=fs.readFileSync(path.join(__dirname,'../actualizacion_20261022_acceso_sedes.sql'),'utf8');await db.exec(migration);await db.exec(migration);
await db.exec(`create policy read_claims on supplier_claims for select using(public.usuario_puede_sede(agency));
insert into auth.users(id,email) select ('00000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'user'||i||'@example.test' from generate_series(1,4)i;
insert into usuarios(auth_user_id,nombre_corto,usuario,activo) select id,'Nombre Corto','usuario-largo',true from auth.users;
insert into usuarios_sedes(user_id,sede,rol,nombre,activo) select id,'TGU',case right(id::text,1) when '1' then 'admin' when '2' then 'operador' else 'consulta' end,'Nombre Completo Largo',true from auth.users;
update usuarios_sedes set activo=false where user_id::text like '%4';
`);
const sites=['SPS','CBA','SRC','TGU','AMT'];async function as(i){await db.exec(`reset role;set role authenticated;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-${String(i).padStart(12,'0')}',false)`)}
for(let i=1;i<=4;i++){await as(i);const profile=(await db.query('select bia_profile() p')).rows[0].p;assert.equal(profile.nombre_corto,'Nombre Corto');assert.equal(profile.is_master,false);assert.equal(profile.is_admin,i===1);assert.equal(profile.sedes.length,i===1?5:i===4?0:1);
 for(const site of sites){const {rows:[r]}=await db.query('select obtener_acceso_sede($1) a, devoluciones_privado.puede_gestionar_entrega($1) w',[site]);assert.equal(r.a.permitido,i===1||(i!==4&&site==='TGU'));assert.equal(r.w,i===1||(i===2&&site==='TGU'));if(i===1||i===2&&site==='TGU')await db.query('insert into supplier_claims(agency,created_by) values($1,auth.uid())',[site]);else await assert.rejects(()=>db.query('insert into supplier_claims(agency,created_by) values($1,auth.uid())',[site]),/row-level security/)}
 assert.equal((await db.query("select usuario_puede_sede('INVALIDA') p")).rows[0].p,false);
}
await as(1);await db.exec("reset role;update auth.users set raw_app_meta_data='{\"must_change_password\":true}' where id::text like '%1';set role authenticated");assert.equal((await db.query("select usuario_puede_sede('SPS') p")).rows[0].p,false);assert.equal((await db.query('select obtener_sedes_usuario() s')).rows[0].s.length,0);await assert.rejects(()=>db.query('select bia_profile()'),/CAMBIO_PASSWORD_REQUERIDO/);
await db.exec("reset role;select set_config('request.jwt.claim.sub','',false);set role anon");assert.equal((await db.query("select usuario_puede_sede('TGU') p")).rows[0].p,false);console.log('PASS admin all five sites; operator own site; consulta read-only; inactive/anon/password-change denied; short name canonical; no master elevation; idempotent migration');await db.close()})().catch(e=>{console.error(e);process.exitCode=1});
