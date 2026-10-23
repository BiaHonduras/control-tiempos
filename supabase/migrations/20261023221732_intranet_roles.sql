create schema if not exists bia_acl_private;
revoke all on schema bia_acl_private from public,anon,authenticated;
create table if not exists bia_acl_private.accounts(
 user_id uuid primary key references auth.users(id) on delete cascade,
 nombre_corto text not null check(length(trim(nombre_corto)) between 2 and 120),
 role text not null check(role in ('consultas','verificador','coordinador','jefatura_zn','jefatura_zc','administrador')),
 sites text[] not null check(cardinality(sites)>0 and sites<@array['SPS','CBA','SRC','TGU','AMT']),
 apps text[] not null check(apps<@array['tiempos','contenedores','devoluciones']),
 active boolean not null default true, protected boolean not null default false,deleted_at timestamptz,
 version int not null default 1,updated_at timestamptz not null default now());
alter table bia_acl_private.accounts enable row level security;
create table if not exists bia_acl_private.audit(id bigint generated always as identity primary key,actor uuid,target uuid,action text,details jsonb,created_at timestamptz default now());
alter table bia_acl_private.audit enable row level security;
create table if not exists bia_acl_private.bootstrap(token_hash text primary key,payload jsonb not null,expires_at timestamptz not null,used_at timestamptz);
alter table bia_acl_private.bootstrap enable row level security;
create table if not exists bia_acl_private.previous_access as select to_jsonb(s) as data from public.usuarios_sedes s;
alter table bia_acl_private.previous_access enable row level security;
revoke all on all tables in schema bia_acl_private from public,anon,authenticated;
insert into bia_acl_private.accounts(user_id,nombre_corto,role,sites,apps,active)
select s.user_id,coalesce(nullif(max(u.nombre_corto),''),nullif(max(s.nombre),''),'Sin nombre corto'),
 case when bool_or(s.rol='admin' and s.activo) then 'coordinador' when bool_or(s.rol='operador' and s.activo) then 'verificador' else 'consultas' end,
 array_agg(distinct s.sede order by s.sede) filter(where s.activo),array['tiempos','contenedores','devoluciones'],bool_or(s.activo)
from public.usuarios_sedes s left join public.usuarios u on u.auth_user_id=s.user_id group by s.user_id having bool_or(s.activo)
on conflict(user_id) do nothing;
-- Keep disabled identities disabled, including accounts without any active site.
insert into bia_acl_private.accounts(user_id,nombre_corto,role,sites,apps,active)
select s.user_id,coalesce(nullif(max(u.nombre_corto),''),nullif(max(s.nombre),''),'Sin nombre corto'),'consultas',array_agg(distinct s.sede),array['tiempos','contenedores','devoluciones'],false
from public.usuarios_sedes s left join public.usuarios u on u.auth_user_id=s.user_id group by s.user_id on conflict(user_id) do nothing;
create or replace function bia_acl_private.role_allows(p_role text,p_action text) returns boolean
language sql immutable set search_path='' as $$select case p_action
 when 'read' then p_role in ('consultas','verificador','coordinador','jefatura_zn','jefatura_zc','administrador')
 when 'write' then p_role in ('verificador','coordinador','jefatura_zn','jefatura_zc','administrador')
 when 'catalogs' then p_role in ('coordinador','jefatura_zn','jefatura_zc','administrador')
 when 'users' then p_role in ('jefatura_zn','jefatura_zc','administrador')
 when 'delete' then p_role='administrador'
 else false end$$;
create or replace function bia_acl_private.can_for(p_user uuid,p_app text,p_action text,p_site text default null) returns boolean
language sql stable security definer set search_path='' as $$
select exists(select 1 from bia_acl_private.accounts a join auth.users u on u.id=a.user_id
where a.user_id=p_user and a.active and a.deleted_at is null
and coalesce(u.raw_app_meta_data->>'must_change_password','false')<>'true'
and (p_app='intranet' or p_app=any(a.apps))
and (p_site is null or upper(p_site)=any(a.sites))
and bia_acl_private.role_allows(a.role,p_action));$$;
create or replace function public.bia_can(p_app text,p_action text,p_sede text default null) returns boolean
language sql stable security definer set search_path='' as $$select bia_acl_private.can_for(auth.uid(),p_app,p_action,p_sede)$$;
revoke all on function public.bia_can(text,text,text) from public,anon;
grant execute on function public.bia_can(text,text,text) to authenticated;
create or replace function public.usuario_es_maestro() returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('intranet','delete')$$;
create or replace function public.usuario_es_admin_global() returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('intranet','delete')$$;
-- Compatibility name: operational RPCs historically used this predicate for data entry.
create or replace function public.usuario_es_admin_sede(p_sede text) returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('tiempos','write',p_sede)$$;
create or replace function public.usuario_puede_sede(p_sede text) returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('intranet','read',p_sede)$$;
create or replace function public.obtener_sedes_usuario() returns text[] language sql stable security definer set search_path='' as $$select coalesce((select sites from bia_acl_private.accounts where user_id=auth.uid() and public.bia_can('intranet','read')),array[]::text[])$$;
create or replace function public.current_user_is_active() returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('intranet','read')$$;
create or replace function public.current_user_role() returns text language sql stable security definer set search_path='' as $$select case when public.bia_can('intranet','delete') then 'admin' when public.bia_can('intranet','write') then 'operador' else 'consulta' end$$;
create or replace function public.current_user_agency() returns text language sql stable security definer set search_path='' as $$select (public.obtener_sedes_usuario())[1]$$;
create or replace function public.usuario_puede_cierre_sede(p_sede text) returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('tiempos','catalogs',p_sede)$$;
create or replace function public.bia_profile(p_sede text default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare a bia_acl_private.accounts;u auth.users;v_name text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 select * into u from auth.users where id=auth.uid();
 if not public.usuario_password_actualizada() then raise exception 'CAMBIO_PASSWORD_REQUERIDO';end if;
 select * into a from bia_acl_private.accounts where user_id=auth.uid();
 v_name:=coalesce((select nullif(trim(nombre_corto),'') from public.usuarios where auth_user_id=auth.uid() limit 1),a.nombre_corto,'Sin nombre corto');
 return jsonb_build_object('id',u.id,'email',u.email,'nombre_corto',v_name,'full_name',v_name,
 'role',case when a.role='administrador' then 'admin' when a.role='consultas' then 'consulta' else 'operador' end,'role_code',a.role,
 'agency',coalesce(case when upper(p_sede)=any(a.sites) then upper(p_sede) end,a.sites[1]),'sedes',coalesce(a.sites,array[]::text[]),
 'applications',coalesce(a.apps,array[]::text[]),'is_active',coalesce(a.active and a.deleted_at is null,false),'is_master',a.role='administrador','is_admin',a.role='administrador',
 'permissions',jsonb_build_object('write',public.bia_can('intranet','write'),'catalogs',public.bia_can('intranet','catalogs'),'users',public.bia_can('intranet','users'),'delete',public.bia_can('intranet','delete')),
 'employee_code','','created_at',u.created_at,'updated_at',a.updated_at);
end$$;
create or replace function public.obtener_acceso_sede(p_sede text) returns jsonb
language sql stable security definer set search_path='' as $$select jsonb_build_object(
 'permitido',public.bia_can('tiempos','read',p_sede),'app_access',public.bia_can('tiempos','read'),'es_maestro',public.bia_can('intranet','delete'),
 'rol',case when public.bia_can('tiempos','write',p_sede) then 'admin' else 'consulta' end,
 'can_manage_catalogs',public.bia_can('tiempos','catalogs',p_sede),'can_delete',public.bia_can('tiempos','delete',p_sede),
 'puede_cierre_dia',public.bia_can('tiempos','catalogs',p_sede),'sedes',public.obtener_sedes_usuario())$$;
create or replace function bia_acl_private.sync_legacy(p_user uuid) returns void
language plpgsql security definer set search_path='' as $$
declare a bia_acl_private.accounts;e text;s text;
begin
 select * into a from bia_acl_private.accounts where user_id=p_user;if not found then return;end if;
 select email into e from auth.users where id=p_user;
 foreach s in array array['SPS','CBA','SRC','TGU','AMT'] loop
 insert into public.usuarios_sedes(user_id,email,nombre,sede,rol,activo,puede_cierre_dia,updated_at)
 values(p_user,e,a.nombre_corto,s,case when a.role='administrador' then 'admin' when a.role='consultas' then 'consulta' else 'operador' end,
 a.active and a.deleted_at is null and s=any(a.sites),a.role in ('coordinador','jefatura_zn','jefatura_zc','administrador'),now())
 on conflict(user_id,sede) do update set email=excluded.email,nombre=excluded.nombre,rol=excluded.rol,activo=excluded.activo,puede_cierre_dia=excluded.puede_cierre_dia,updated_at=now();
 end loop;
 perform bia_identity_private.sync_identity(p_user);
 update public.usuarios set nombre_corto=a.nombre_corto,activo=a.active and a.deleted_at is null where auth_user_id=p_user;
end$$;
create or replace function public.bia_directory_list(p_deleted boolean default false) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',a.user_id,'nombre_corto',coalesce(pub.nombre_corto,a.nombre_corto),'email',u.email,'role',a.role,'sites',a.sites,'apps',a.apps,'active',a.active,'deleted',a.deleted_at is not null,'version',a.version,'protected',a.protected) order by coalesce(pub.nombre_corto,a.nombre_corto)),'[]'::jsonb)
 from bia_acl_private.accounts a join auth.users u on u.id=a.user_id left join public.usuarios pub on pub.auth_user_id=a.user_id
 where public.bia_can('intranet','users') and (p_deleted or a.deleted_at is null)
 and (public.bia_can('intranet','delete') or (a.user_id=auth.uid() or (a.role in ('consultas','verificador','coordinador') and a.sites<@public.obtener_sedes_usuario())));
$$;
revoke all on function public.bia_directory_list(boolean) from public,anon;
grant execute on function public.bia_directory_list(boolean) to authenticated;
-- Legacy user editors are closed; all user changes pass through the Intranet service.
create or replace function public.bia_list_users() returns jsonb language sql stable security definer set search_path='' as $$select '[]'::jsonb$$;
create or replace function public.bia_update_access(p_user_id uuid,p_sede text,p_role text,p_active boolean,p_name text) returns boolean language plpgsql security definer set search_path='' as $$begin raise exception 'GESTION_DE_USUARIOS_EN_INTRANET';end$$;
create or replace function public.master_cambiar_estado_acceso(p_user_id uuid,p_sede text,p_activo boolean) returns boolean language plpgsql security definer set search_path='' as $$begin raise exception 'GESTION_DE_USUARIOS_EN_INTRANET';end$$;
create or replace function public.master_asignar_usuario_existente(p_email text,p_nombre text,p_sede text,p_rol text,p_puede_cierre boolean) returns boolean language plpgsql security definer set search_path='' as $$begin raise exception 'GESTION_DE_USUARIOS_EN_INTRANET';end$$;
create or replace function public.listar_usuarios_sede_v1(p_sede text) returns table(user_id uuid,email text,nombre text,sede text,rol text,puede_cierre_dia boolean,activo boolean)
language sql stable security definer set search_path='' as $$select s.user_id,s.email::text,s.nombre::text,s.sede::text,s.rol::text,s.puede_cierre_dia,s.activo from public.usuarios_sedes s where false$$;
create or replace function public.bia_directory_check(p_actor uuid,p_action text,p_target uuid default null,p_data jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor bia_acl_private.accounts;target bia_acl_private.accounts;sites text[];apps text[];role text;
begin
 if not bia_acl_private.can_for(p_actor,'intranet','users') then raise exception 'SIN_PERMISO_USUARIOS';end if;
 select * into actor from bia_acl_private.accounts where user_id=p_actor;
 if p_action not in ('create','edit','delete','toggle','reset','restore') then raise exception 'ACCION_INVALIDA';end if;
 if p_action in ('delete','toggle','restore') and actor.role<>'administrador' then raise exception 'SOLO_ADMINISTRADOR';end if;
 if p_target is not null then
 select * into target from bia_acl_private.accounts where user_id=p_target;
 if not found then raise exception 'USUARIO_NO_ENCONTRADO';end if;
 if p_target=p_actor and p_action<>'reset' then raise exception 'NO_CAMBIES_TU_PROPIO_ACCESO';end if;
 if actor.role<>'administrador' and (target.role not in ('consultas','verificador','coordinador') or not target.sites<@actor.sites) then raise exception 'USUARIO_FUERA_DE_TU_ALCANCE';end if;
 if target.protected and p_action in ('delete','toggle') then raise exception 'CUENTA_DE_EMERGENCIA_PROTEGIDA';end if;
 end if;
 if p_action in ('create','edit') then
 role:=p_data->>'role';sites:=array(select jsonb_array_elements_text(p_data->'sites'));apps:=array(select jsonb_array_elements_text(p_data->'apps'));
 if role not in ('consultas','verificador','coordinador','jefatura_zn','jefatura_zc','administrador') or role is null then raise exception 'ROL_INVALIDO';end if;
 if cardinality(sites)=0 or not sites<@array['SPS','CBA','SRC','TGU','AMT'] or not apps<@array['tiempos','contenedores','devoluciones'] then raise exception 'ACCESOS_INVALIDOS';end if;
 if length(trim(coalesce(p_data->>'nombre_corto',''))) not between 2 and 120 then raise exception 'NOMBRE_CORTO_INVALIDO';end if;
 if actor.role<>'administrador' and (role not in ('consultas','verificador','coordinador') or not sites<@actor.sites or not apps<@actor.apps) then raise exception 'NO_PUEDES_OTORGAR_ESOS_PERMISOS';end if;
 if role='administrador' and (not sites@>array['SPS','CBA','SRC','TGU','AMT'] or not apps@>array['tiempos','contenedores','devoluciones']) then raise exception 'ADMINISTRADOR_REQUIERE_TODOS_LOS_ACCESOS';end if;
 if role='jefatura_zn' and not sites<@array['SPS','CBA','SRC'] then raise exception 'BODEGAS_FUERA_DE_ZONA_NORTE';end if;
 if role='jefatura_zc' and not sites<@array['TGU','AMT'] then raise exception 'BODEGAS_FUERA_DE_ZONA_CENTRO';end if;
 if target.protected and (role<>'administrador' or sites<>array['SPS','CBA','SRC','TGU','AMT'] or cardinality(apps)<>3) then raise exception 'CUENTA_DE_EMERGENCIA_PROTEGIDA';end if;
 end if;
 return jsonb_build_object('ok',true,'target',p_target);
end$$;
create or replace function public.bia_directory_apply(p_actor uuid,p_target uuid,p_action text,p_data jsonb default '{}',p_version int default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a bia_acl_private.accounts;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_target::text,0));
 perform public.bia_directory_check(p_actor,p_action,p_target,p_data);
 select * into a from bia_acl_private.accounts where user_id=p_target for update;
 if a.user_id is not null and (p_version is null or a.version<>p_version) then raise exception 'EL_USUARIO_CAMBIO_ACTUALIZA_EL_LISTADO';end if;
 if p_action='edit' then
 update bia_acl_private.accounts set nombre_corto=trim(p_data->>'nombre_corto'),role=p_data->>'role',sites=array(select jsonb_array_elements_text(p_data->'sites')),apps=array(select jsonb_array_elements_text(p_data->'apps')),version=version+1,updated_at=now() where user_id=p_target;
 elsif p_action='delete' then update bia_acl_private.accounts set deleted_at=now(),active=false,version=version+1,updated_at=now() where user_id=p_target;
 elsif p_action='restore' then update bia_acl_private.accounts set deleted_at=null,active=true,version=version+1,updated_at=now() where user_id=p_target;
 elsif p_action='toggle' then update bia_acl_private.accounts set active=coalesce((p_data->>'active')::boolean,not active),version=version+1,updated_at=now() where user_id=p_target;
 elsif p_action='reset' then null;
 else raise exception 'ACCION_NO_APLICABLE';end if;
 perform bia_acl_private.sync_legacy(p_target);
 insert into bia_acl_private.audit(actor,target,action,details) values(p_actor,p_target,p_action,case when p_action='edit' then p_data else '{}'::jsonb end);
 return jsonb_build_object('ok',true);
end$$;
create or replace function public.bia_directory_create(p_actor uuid,p_target uuid,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 perform public.bia_directory_check(p_actor,'create',null,p_data);
 if exists(select 1 from bia_acl_private.accounts where user_id=p_target) then raise exception 'USUARIO_YA_EXISTE_EDITA_SU_REGISTRO';end if;
 insert into bia_acl_private.accounts(user_id,nombre_corto,role,sites,apps) values(p_target,trim(p_data->>'nombre_corto'),p_data->>'role',array(select jsonb_array_elements_text(p_data->'sites')),array(select jsonb_array_elements_text(p_data->'apps')));
 perform bia_acl_private.sync_legacy(p_target);
 insert into bia_acl_private.audit(actor,target,action,details) values(p_actor,p_target,'create',p_data);
 return jsonb_build_object('ok',true);
end$$;
create or replace function public.bia_bootstrap_claim(p_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$declare v jsonb;begin
 update bia_acl_private.bootstrap set used_at=now() where token_hash=p_hash and used_at is null and expires_at>now() returning payload into v;
 if v is null then raise exception 'BOOTSTRAP_NO_AUTORIZADO';end if;return v;
end$$;
create or replace function public.bia_bootstrap_assign(p_target uuid,p_data jsonb) returns void
language plpgsql security definer set search_path='' as $$begin
 if not exists(select 1 from bia_acl_private.bootstrap b,jsonb_array_elements(b.payload) x where b.used_at>now()-interval '15 minutes' and lower(x->>'email')=(select lower(email) from auth.users where id=p_target) and x=p_data) then raise exception 'BOOTSTRAP_NO_AUTORIZADO';end if;
 insert into bia_acl_private.accounts(user_id,nombre_corto,role,sites,apps,active,protected) values(p_target,p_data->>'nombre_corto',p_data->>'role',array(select jsonb_array_elements_text(p_data->'sites')),array['tiempos','contenedores','devoluciones'],true,coalesce((p_data->>'protected')::boolean,false))
 on conflict(user_id) do update set nombre_corto=excluded.nombre_corto,role=excluded.role,sites=excluded.sites,apps=excluded.apps,active=true,deleted_at=null,protected=excluded.protected,version=bia_acl_private.accounts.version+1,updated_at=now();
 perform bia_acl_private.sync_legacy(p_target);
end$$;
-- Service-only endpoints are never callable by browser roles, even with forged actor IDs.
revoke all on function public.bia_directory_check(uuid,text,uuid,jsonb),public.bia_directory_apply(uuid,uuid,text,jsonb,int),public.bia_directory_create(uuid,uuid,jsonb),public.bia_bootstrap_claim(text),public.bia_bootstrap_assign(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.bia_directory_check(uuid,text,uuid,jsonb),public.bia_directory_apply(uuid,uuid,text,jsonb,int),public.bia_directory_create(uuid,uuid,jsonb),public.bia_bootstrap_claim(text),public.bia_bootstrap_assign(uuid,jsonb) to service_role;
revoke all on all functions in schema bia_acl_private from public,anon,authenticated;

-- INTRANET_CORE_END
do $acl$begin if to_regprocedure('public.admin_actualizar_registro_historial_v3(text,uuid,jsonb,text)') is not null then execute 'revoke all on function public.admin_actualizar_registro_historial_v3(text,uuid,jsonb,text) from public,anon,authenticated;';end if;end$acl$;

CREATE OR REPLACE FUNCTION public.pausar_cronometro_sede_v1(p_id uuid, p_expected_version integer, p_motivo text, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;tot integer;em text;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;if length(trim(coalesce(p_motivo,'')))<3 then raise exception 'MOTIVO_REQUERIDO';end if;
 select * into v from public.cronometros where id=p_id and sede=s for update;if not found then raise exception 'NO_ENCONTRADO';end if;if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT';end if;if v.estado<>'ejecucion' then raise exception 'ESTADO_INVALIDO';end if;
 tot=v.segundos_acumulados+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int);select email into em from auth.users where id=auth.uid();insert into public.pausas_cronometros(cronometro_id,motivo,pausado_por,pausado_por_email,sede) values(v.id,trim(p_motivo),auth.uid(),em,s);
 update public.cronometros set estado='pausado',inicio=null,segundos_acumulados=tot,version=version+1,actualizado_por=auth.uid(),actualizado_en=now() where id=p_id and sede=s returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.pausar_cronometro_sede_v1(uuid,integer,text,text)') is not null then execute 'revoke all on function public.pausar_cronometro_sede_v1(uuid,integer,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.pausar_cronometro_sede_v1(uuid,integer,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.cambiar_estado_cronometro_sede_v1(p_id uuid, p_expected_version integer, p_accion text, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if p_accion='pause' then return public.pausar_cronometro_sede_v1(p_id,p_expected_version,'Pausa operativa',p_sede);elsif p_accion='resume' then return public.reanudar_cronometro_sede_v1(p_id,p_expected_version,p_sede);else raise exception 'ACCION_INVALIDA';end if;end $function$;

do $acl$begin if to_regprocedure('public.cambiar_estado_cronometro_sede_v1(uuid,integer,text,text)') is not null then execute 'revoke all on function public.cambiar_estado_cronometro_sede_v1(uuid,integer,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.cambiar_estado_cronometro_sede_v1(uuid,integer,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.retirar_colaborador_sede_v1(p_cronometro_id uuid, p_expected_version integer, p_colaborador_id uuid, p_motivo text, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;tot integer;em text;ids uuid[];nombres text[];cnt integer;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;if length(trim(coalesce(p_motivo,'')))<3 then raise exception 'MOTIVO_REQUERIDO';end if;
 select * into v from public.cronometros where id=p_cronometro_id and sede=s for update;if not found then raise exception 'NO_ENCONTRADO';end if;if v.categoria<>'actividad' or v.estado not in('ejecucion','pausado') then raise exception 'ACTIVIDAD_NO_ACTIVA';end if;if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT';end if;
 select count(*) into cnt from public.actividad_participaciones where cronometro_id=p_cronometro_id and sede=s and estado='activo';if cnt<=1 then raise exception 'NO_PUEDE_RETIRAR_ULTIMO_PARTICIPANTE';end if;
 tot=v.segundos_acumulados;if v.estado='ejecucion' and v.inicio is not null then tot=tot+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int);end if;select email into em from auth.users where id=auth.uid();
 update public.actividad_participaciones set segundos_fin=tot,segundos=greatest(0,tot-segundos_inicio),estado='retirado',motivo_retiro=trim(p_motivo),retirado_por=auth.uid(),retirado_por_email=em,retirado_en=now(),updated_at=now() where cronometro_id=p_cronometro_id and colaborador_id=p_colaborador_id and sede=s and estado='activo';if not found then raise exception 'COLABORADOR_NO_PARTICIPA';end if;
 select array_agg(colaborador_id order by colaborador_nombre),array_agg(colaborador_nombre order by colaborador_nombre) into ids,nombres from public.actividad_participaciones where cronometro_id=p_cronometro_id and sede=s and estado='activo';
 update public.cronometros set colaborador_id=ids[1],empleado=array_to_string(nombres,', '),datos=jsonb_set(jsonb_set(datos,'{participantes_ids}',to_jsonb(ids),true),'{participantes_nombres}',to_jsonb(nombres),true),version=version+1,actualizado_por=auth.uid(),actualizado_en=now() where id=p_cronometro_id and sede=s returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.retirar_colaborador_sede_v1(uuid,integer,uuid,text,text)') is not null then execute 'revoke all on function public.retirar_colaborador_sede_v1(uuid,integer,uuid,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.retirar_colaborador_sede_v1(uuid,integer,uuid,text,text) to authenticated;

CREATE OR REPLACE FUNCTION devoluciones_privado.modificar_gestion(p_id uuid, p_version integer, p_datos jsonb, p_items jsonb, p_eliminar boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.devoluciones; v_actor text; v_item jsonb; v_before jsonb; v_after jsonb; v_count integer; v_changes text; v_quantities text;
begin
 if p_eliminar and not public.bia_can('devoluciones','delete') then raise exception 'SOLO_ADMINISTRADOR';end if;
 if auth.uid() is null or not devoluciones_privado.autorizado() then raise exception 'Inicia sesión para continuar'; end if;
 select * into v from public.devoluciones where id=p_id and eliminado_at is null for update;
 if not found then raise exception 'Gestión no encontrada o eliminada'; end if;
 if not public.bia_can('devoluciones','write',v.sede) then raise exception 'Sin permiso para modificar esta gestión'; end if;
 if p_version is null or v.version<>p_version then raise exception 'La gestión cambió. Actualiza el listado antes de continuar'; end if;
 select coalesce(nombre_corto,usuario) into v_actor from public.usuarios where auth_user_id=auth.uid() and activo is true limit 1;
 if coalesce(p_eliminar,false) then
  update public.devoluciones set eliminado_at=now(),eliminado_por=auth.uid(),version=version+1 where id=p_id;
  insert into public.devoluciones_historial(devolucion_id,actor,actor_nombre,estado_anterior,estado_nuevo,comentario)
  values(p_id,auth.uid(),coalesce(v_actor,''),v.estado,v.estado,'[Eliminación] Gestión retirada del listado. Se conserva su registro para auditoría.');
  return;
 end if;
 if p_datos is null or jsonb_typeof(p_datos)<>'object' then raise exception 'Datos de edición no válidos'; end if;
 if length(trim(coalesce(p_datos->>'factura',''))) not between 1 and 120 or length(trim(coalesce(p_datos->>'bodega_origen',''))) not between 1 and 120 or length(trim(coalesce(p_datos->>'bodega_destino',''))) not between 1 and 120 or length(coalesce(p_datos->>'comentario',''))>4000 then raise exception 'Revisa factura, bodegas y comentario'; end if;
 if not exists(select 1 from public.negocio where nombre=p_datos->>'cliente') or not exists(select 1 from public.observaciones where nombre=p_datos->>'observacion') then raise exception 'Selecciona cliente y observación del catálogo'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Revisa los productos'; end if;
 select count(*) into v_count from public.devoluciones_detalle where devolucion_id=p_id;
 if jsonb_array_length(p_items)<>v_count or v_count=0 then raise exception 'Los productos cambiaron. Abre nuevamente la edición'; end if;
 if (select count(distinct value->>'id') from jsonb_array_elements(p_items))<>v_count then raise exception 'Productos duplicados'; end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  if not exists(select 1 from public.devoluciones_detalle where devolucion_id=p_id and id::text=v_item->>'id') then raise exception 'Producto fuera de esta gestión'; end if;
  if (v_item->>'cantidad') is null or (v_item->>'cantidad') !~ '^[0-9]{1,12}([.][0-9]{1,4})?$' or (v_item->>'cantidad')::numeric<=0 then raise exception 'Cantidad no válida'; end if;
 end loop;
 select jsonb_build_object('factura',v.factura,'cliente',v.cliente,'observacion',v.observacion,'bodega_origen',v.bodega_origen,'bodega_destino',v.bodega_destino,'comentario',v.comentario,'items',(select jsonb_agg(jsonb_build_object('id',id,'codigo',codigo,'cantidad',cantidad) order by id) from public.devoluciones_detalle where devolucion_id=p_id)) into v_before;
 update public.devoluciones set factura=trim(p_datos->>'factura'),cliente=p_datos->>'cliente',observacion=p_datos->>'observacion',bodega_origen=trim(p_datos->>'bodega_origen'),bodega_destino=trim(p_datos->>'bodega_destino'),comentario=coalesce(p_datos->>'comentario',''),version=version+1 where id=p_id;
 for v_item in select value from jsonb_array_elements(p_items) loop
  update public.devoluciones_detalle set cantidad=(v_item->>'cantidad')::numeric where devolucion_id=p_id and id::text=v_item->>'id';
 end loop;
 v_after:=p_datos||jsonb_build_object('items',p_items);
 select string_agg((case key when 'factura' then 'Factura' when 'cliente' then 'Cliente' when 'observacion' then 'Observación' when 'bodega_origen' then 'Bodega origen' when 'bodega_destino' then 'Bodega destino' else 'Comentario' end)||': '||coalesce(v_before->>key,'')||' → '||value,'; ' order by key) into v_changes from jsonb_each_text(p_datos) where key in ('factura','cliente','observacion','bodega_origen','bodega_destino','comentario') and value is distinct from v_before->>key;
 select string_agg('Código '||(a.value->>'codigo')||': cantidad '||(a.value->>'cantidad')||' → '||(b.value->>'cantidad'),'; ') into v_quantities from jsonb_array_elements(v_before->'items') a join jsonb_array_elements(p_items) b on a.value->>'id'=b.value->>'id' where (a.value->>'cantidad')::numeric is distinct from (b.value->>'cantidad')::numeric;
 insert into public.devoluciones_historial(devolucion_id,actor,actor_nombre,estado_anterior,estado_nuevo,comentario)
 values(p_id,auth.uid(),coalesce(v_actor,''),v.estado,v.estado,'[Edición] '||coalesce(nullif(concat_ws('; ',v_changes,v_quantities),''),'Datos confirmados sin cambios'));
end $function$;

do $acl$begin if to_regprocedure('public.admin_eliminar_registro_historial(text,uuid,text)') is not null then execute 'revoke all on function public.admin_eliminar_registro_historial(text,uuid,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_cronometro(text,text,jsonb)') is not null then execute 'revoke all on function public.iniciar_cronometro(text,text,jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_actualizar_registro_historial(text,uuid,jsonb,text)') is not null then execute 'revoke all on function public.admin_actualizar_registro_historial(text,uuid,jsonb,text) from public,anon,authenticated;';end if;end$acl$;

CREATE OR REPLACE FUNCTION public.cambiar_estado_colaborador_sede_v1(p_id uuid, p_activo boolean, p_sede text)
 RETURNS colaboradores
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.colaboradores;s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 if not p_activo and exists(select 1 from public.cronometros where sede=s and colaborador_id=p_id and estado in('ejecucion','pausado')) then raise exception 'COLABORADOR_EN_PROCESO_ACTIVO'; end if;
 update public.colaboradores set activo=p_activo,updated_at=now() where id=p_id and sede=s returning * into v;
 if v.id is null then raise exception 'COLABORADOR_NO_ENCONTRADO'; end if; return v;
end $function$;

do $acl$begin if to_regprocedure('public.cambiar_estado_colaborador_sede_v1(uuid,boolean,text)') is not null then execute 'revoke all on function public.cambiar_estado_colaborador_sede_v1(uuid,boolean,text) from public,anon;';end if;end$acl$;

grant execute on function public.cambiar_estado_colaborador_sede_v1(uuid,boolean,text) to authenticated;

CREATE OR REPLACE FUNCTION public.cambiar_estado_actividad_sede_v1(p_id uuid, p_activo boolean, p_sede text)
 RETURNS actividades_catalogo
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.actividades_catalogo;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 update public.actividades_catalogo set activo=p_activo,actualizado_por=auth.uid(),updated_at=now() where id=p_id and sede=s returning * into v;
 if v.id is null then raise exception 'ACTIVIDAD_NO_ENCONTRADA'; end if;return v;end $function$;

do $acl$begin if to_regprocedure('public.cambiar_estado_actividad_sede_v1(uuid,boolean,text)') is not null then execute 'revoke all on function public.cambiar_estado_actividad_sede_v1(uuid,boolean,text) from public,anon;';end if;end$acl$;

grant execute on function public.cambiar_estado_actividad_sede_v1(uuid,boolean,text) to authenticated;

do $acl$begin if to_regprocedure('public.cancelar_cronometro(uuid,integer)') is not null then execute 'revoke all on function public.cancelar_cronometro(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_pausar_cronometro_v2(uuid,integer,text)') is not null then execute 'revoke all on function public.admin_pausar_cronometro_v2(uuid,integer,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v2(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v2(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_reanudar_cronometro_v2(uuid,integer)') is not null then execute 'revoke all on function public.admin_reanudar_cronometro_v2(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_cronometro_v4(text,uuid,jsonb)') is not null then execute 'revoke all on function public.iniciar_cronometro_v4(text,uuid,jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v4(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v4(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_guardar_ausencia(uuid,date,numeric,text,text)') is not null then execute 'revoke all on function public.admin_guardar_ausencia(uuid,date,numeric,text,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_cronometro_v2(text,uuid,jsonb)') is not null then execute 'revoke all on function public.iniciar_cronometro_v2(text,uuid,jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_guardar_colaborador(uuid,text,text)') is not null then execute 'revoke all on function public.admin_guardar_colaborador(uuid,text,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_cambiar_estado_colaborador(uuid,boolean)') is not null then execute 'revoke all on function public.admin_cambiar_estado_colaborador(uuid,boolean) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.finalizar_cronometro(uuid,integer)') is not null then execute 'revoke all on function public.finalizar_cronometro(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v3(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v3(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.cambiar_estado_cronometro(uuid,integer,text)') is not null then execute 'revoke all on function public.cambiar_estado_cronometro(uuid,integer,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_guardar_ausencia_v3(uuid,date,numeric,text,text)') is not null then execute 'revoke all on function public.admin_guardar_ausencia_v3(uuid,date,numeric,text,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_eliminar_ausencia_v2(uuid)') is not null then execute 'revoke all on function public.admin_eliminar_ausencia_v2(uuid) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.configurar_permiso_cierre_sede_v1(uuid,boolean,text)') is not null then execute 'revoke all on function public.configurar_permiso_cierre_sede_v1(uuid,boolean,text) from public,anon,authenticated;';end if;end$acl$;

CREATE OR REPLACE FUNCTION public.eliminar_actividad_catalogo_sede_v1(p_id uuid, p_sede text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n text;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 select nombre into n from public.actividades_catalogo where id=p_id and sede=s for update;if n is null then raise exception 'ACTIVIDAD_NO_ENCONTRADA'; end if;
 if exists(select 1 from public.historial_actividades where sede=s and actividad=n) or exists(select 1 from public.cronometros where sede=s and categoria='actividad' and datos->>'actividad'=n) or exists(select 1 from public.actividad_participaciones where sede=s and actividad=n) then raise exception 'ACTIVIDAD_EN_USO_USE_DESACTIVAR'; end if;
 delete from public.actividades_catalogo where id=p_id and sede=s;return true;end $function$;

do $acl$begin if to_regprocedure('public.eliminar_actividad_catalogo_sede_v1(uuid,text)') is not null then execute 'revoke all on function public.eliminar_actividad_catalogo_sede_v1(uuid,text) from public,anon;';end if;end$acl$;

grant execute on function public.eliminar_actividad_catalogo_sede_v1(uuid,text) to authenticated;

CREATE OR REPLACE FUNCTION public.cancelar_cronometro_sede_v1(p_id uuid, p_expected_version integer, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;select * into v from public.cronometros where id=p_id and sede=s for update;if not found then raise exception 'NO_ENCONTRADO';end if;if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT';end if;
 update public.actividad_participaciones set estado='cancelado',updated_at=now() where cronometro_id=p_id and sede=s and estado='activo';update public.preparacion_participaciones set estado='cancelado',updated_at=now() where cronometro_id=p_id and sede=s and estado='activo';
 update public.cronometros set estado='cancelado',inicio=null,version=version+1,actualizado_por=auth.uid(),actualizado_en=now(),finalizado_en=now() where id=p_id and sede=s returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.cancelar_cronometro_sede_v1(uuid,integer,text)') is not null then execute 'revoke all on function public.cancelar_cronometro_sede_v1(uuid,integer,text) from public,anon;';end if;end$acl$;

grant execute on function public.cancelar_cronometro_sede_v1(uuid,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION public.eliminar_ausencia_sede_v1(p_id uuid, p_sede text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if; if not public.usuario_es_admin_sede(p_sede) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;delete from public.ausencias_personal where id=p_id and sede=upper(p_sede);if not found then raise exception 'AUSENCIA_NO_ENCONTRADA';end if;return true;end $function$;

do $acl$begin if to_regprocedure('public.eliminar_ausencia_sede_v1(uuid,text)') is not null then execute 'revoke all on function public.eliminar_ausencia_sede_v1(uuid,text) from public,anon;';end if;end$acl$;

grant execute on function public.eliminar_ausencia_sede_v1(uuid,text) to authenticated;

do $acl$begin if to_regprocedure('public.admin_guardar_actividad_catalogo(uuid,text,integer,integer,integer)') is not null then execute 'revoke all on function public.admin_guardar_actividad_catalogo(uuid,text,integer,integer,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_cambiar_estado_actividad_catalogo(uuid,boolean)') is not null then execute 'revoke all on function public.admin_cambiar_estado_actividad_catalogo(uuid,boolean) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_eliminar_actividad_catalogo(uuid)') is not null then execute 'revoke all on function public.admin_eliminar_actividad_catalogo(uuid) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v9(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v9(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_listar_usuarios_cierre()') is not null then execute 'revoke all on function public.admin_listar_usuarios_cierre() from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_configurar_permiso_cierre(uuid,boolean)') is not null then execute 'revoke all on function public.admin_configurar_permiso_cierre(uuid,boolean) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.cancelar_cronometro_v5(uuid,integer)') is not null then execute 'revoke all on function public.cancelar_cronometro_v5(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.gestionar_cierre_dia(date,text,text)') is not null then execute 'revoke all on function public.gestionar_cierre_dia(date,text,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v5(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v5(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_cronometro_v5(text,uuid,jsonb)') is not null then execute 'revoke all on function public.iniciar_cronometro_v5(text,uuid,jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_retirar_colaborador_actividad(uuid,integer,uuid,text)') is not null then execute 'revoke all on function public.admin_retirar_colaborador_actividad(uuid,integer,uuid,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_eliminar_ausencia(uuid)') is not null then execute 'revoke all on function public.admin_eliminar_ausencia(uuid) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_guardar_metas_productividad(numeric,numeric,numeric,integer)') is not null then execute 'revoke all on function public.admin_guardar_metas_productividad(numeric,numeric,numeric,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_cerrar_dia(date,text)') is not null then execute 'revoke all on function public.admin_cerrar_dia(date,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.finalizar_cronometro_v5(uuid,integer)') is not null then execute 'revoke all on function public.finalizar_cronometro_v5(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

CREATE OR REPLACE FUNCTION public.reporte_errores_preparacion_sede_v2(p_desde date, p_hasta date, p_sede text)
 RETURNS TABLE(error_id uuid, historial_preparacion_id uuid, fecha_preparacion date, tipo_error text, cantidad integer, numero_reporte integer, zona text, tipo_pedido text, facturas integer, libras numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      declare
        s text:=upper(trim(p_sede));
      begin
 if not public.bia_can('tiempos','read',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
        if auth.uid() is null then
          raise exception 'AUTH_REQUIRED';
        end if;

        if s not in ('SPS','CBA','SRC','TGU','AMT') then
          raise exception 'SEDE_INVALIDA';
        end if;

        if p_desde is null or p_hasta is null then
          raise exception 'RANGO_FECHAS_REQUERIDO';
        end if;

        if p_desde > p_hasta then
          raise exception 'RANGO_FECHAS_INVALIDO';
        end if;

        if not public.usuario_puede_sede(s) then
          raise exception 'SIN_ACCESO_SEDE';
        end if;

        return query
        select
          e.id,
          e.historial_preparacion_id,
          e.fecha_preparacion,
          e.tipo_error,
          e.cantidad,
          ep.numero_reporte,
          h.zona,
          h.tipo,
          h.facturas,
          h.libras
        from public.errores_preparacion e
        join public.errores_preparacion_participantes ep
          on ep.error_id=e.id
         and ep.sede=e.sede
        join public.historial_preparaciones h
          on h.id=e.historial_preparacion_id
         and h.sede=e.sede
        where e.sede=s
          and e.fecha_preparacion between p_desde and p_hasta
        order by e.fecha_preparacion,ep.numero_reporte,e.created_at;
      end
      $function$;

do $acl$begin if to_regprocedure('public.reporte_errores_preparacion_sede_v2(date,date,text)') is not null then execute 'revoke all on function public.reporte_errores_preparacion_sede_v2(date,date,text) from public,anon;';end if;end$acl$;

grant execute on function public.reporte_errores_preparacion_sede_v2(date,date,text) to authenticated;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v6(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v6(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_preparacion_v6(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_preparacion_v6(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.finalizar_cronometro_v6(uuid,integer)') is not null then execute 'revoke all on function public.finalizar_cronometro_v6(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.cancelar_cronometro_v6(uuid,integer)') is not null then execute 'revoke all on function public.cancelar_cronometro_v6(uuid,integer) from public,anon,authenticated;';end if;end$acl$;

CREATE OR REPLACE FUNCTION public.guardar_error_preparacion_sede_v1(p_id uuid, p_historial_id uuid, p_tipo_error text, p_cantidad integer, p_observacion text, p_colaborador_ids uuid[], p_sede text)
 RETURNS errores_preparacion
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s text:=upper(p_sede);
  h public.historial_preparaciones;
  v_error public.errores_preparacion;
  v_ids uuid[];
  v_id uuid;
  v_numero integer;
  v_email text;
  v_tiene_participaciones boolean;
begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;

  select *
  into h
  from public.historial_preparaciones
  where id=p_historial_id and sede=s;

  if not found then raise exception 'PREPARACION_NO_ENCONTRADA'; end if;

  if length(trim(coalesce(p_tipo_error,'')))<3 then
    raise exception 'TIPO_ERROR_REQUERIDO';
  end if;

  if p_cantidad is null or p_cantidad<=0 then
    raise exception 'CANTIDAD_ERROR_INVALIDA';
  end if;

  select array_agg(id order by id::text)
  into v_ids
  from(
    select distinct unnest(coalesce(p_colaborador_ids,array[]::uuid[])) id
  ) q;

  if v_ids is null or cardinality(v_ids)=0 then
    raise exception 'COLABORADOR_REQUERIDO';
  end if;

  select exists(
    select 1
    from public.preparacion_participaciones pp
    where pp.sede=s and pp.cronometro_id=h.timer_id
  )
  into v_tiene_participaciones;

  foreach v_id in array v_ids loop
    if v_tiene_participaciones then
      if not exists(
        select 1
        from public.preparacion_participaciones pp
        where pp.sede=s
          and pp.cronometro_id=h.timer_id
          and pp.colaborador_id=v_id
      ) then
        raise exception 'COLABORADOR_NO_PARTICIPO_EN_PREPARACION';
      end if;
    else
      if not exists(
        select 1
        from public.colaboradores c
        where c.id=v_id
          and c.sede=s
          and (
            c.id=h.colaborador_id
            or c.nombre=any(string_to_array(coalesce(h.empleado,''),', '))
          )
      ) then
        raise exception 'COLABORADOR_NO_PARTICIPO_EN_PREPARACION';
      end if;
    end if;
  end loop;

  select email into v_email
  from auth.users
  where id=auth.uid();

  if p_id is null then
    insert into public.errores_preparacion(
      sede,historial_preparacion_id,timer_id,fecha_preparacion,
      tipo_error,cantidad,observacion,registrado_por,registrado_por_email
    ) values(
      s,h.id,h.timer_id,h.fecha_preparacion,
      trim(p_tipo_error),p_cantidad,nullif(trim(coalesce(p_observacion,'')),''),
      auth.uid(),v_email
    )
    returning * into v_error;
  else
    update public.errores_preparacion
    set tipo_error=trim(p_tipo_error),
        cantidad=p_cantidad,
        observacion=nullif(trim(coalesce(p_observacion,'')),''),
        updated_at=now()
    where id=p_id
      and sede=s
      and historial_preparacion_id=h.id
    returning * into v_error;

    if not found then raise exception 'ERROR_PREPARACION_NO_ENCONTRADO'; end if;

    delete from public.errores_preparacion_participantes
    where error_id=v_error.id and sede=s;
  end if;

  foreach v_id in array v_ids loop
    select numero_reporte
    into v_numero
    from public.colaboradores
    where id=v_id and sede=s;

    if v_numero is null then
      raise exception 'COLABORADOR_SIN_NUMERO_REPORTE';
    end if;

    insert into public.errores_preparacion_participantes(
      error_id,sede,colaborador_id,numero_reporte
    ) values(
      v_error.id,s,v_id,v_numero
    )
    on conflict(error_id,colaborador_id)
    do update set numero_reporte=excluded.numero_reporte,sede=excluded.sede;
  end loop;

  return v_error;
end $function$;

do $acl$begin if to_regprocedure('public.guardar_error_preparacion_sede_v1(uuid,uuid,text,integer,text,uuid[],text)') is not null then execute 'revoke all on function public.guardar_error_preparacion_sede_v1(uuid,uuid,text,integer,text,uuid[],text) from public,anon;';end if;end$acl$;

grant execute on function public.guardar_error_preparacion_sede_v1(uuid,uuid,text,integer,text,uuid[],text) to authenticated;

CREATE OR REPLACE FUNCTION public.eliminar_error_preparacion_sede_v1(p_id uuid, p_sede text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','delete',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;

  delete from public.errores_preparacion
  where id=p_id and sede=s;

  if not found then raise exception 'ERROR_PREPARACION_NO_ENCONTRADO'; end if;
  return true;
end $function$;

do $acl$begin if to_regprocedure('public.eliminar_error_preparacion_sede_v1(uuid,text)') is not null then execute 'revoke all on function public.eliminar_error_preparacion_sede_v1(uuid,text) from public,anon;';end if;end$acl$;

grant execute on function public.eliminar_error_preparacion_sede_v1(uuid,text) to authenticated;

CREATE OR REPLACE FUNCTION public.reporte_errores_preparacion_sede_v1(p_desde date, p_hasta date, p_sede text)
 RETURNS TABLE(error_id uuid, historial_preparacion_id uuid, fecha_preparacion date, tipo_error text, cantidad integer, numero_reporte integer, zona text, tipo_pedido text, facturas integer, libras numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','read',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.usuario_puede_sede(s) then raise exception 'SIN_ACCESO_SEDE'; end if;

  return query
  select
    e.id,
    e.historial_preparacion_id,
    e.fecha_preparacion,
    e.tipo_error,
    e.cantidad,
    ep.numero_reporte,
    h.zona,
    h.tipo,
    h.facturas,
    h.libras
  from public.errores_preparacion e
  join public.errores_preparacion_participantes ep
    on ep.error_id=e.id and ep.sede=e.sede
  join public.historial_preparaciones h
    on h.id=e.historial_preparacion_id and h.sede=e.sede
  where e.sede=s
    and e.fecha_preparacion between p_desde and p_hasta
  order by e.fecha_preparacion,ep.numero_reporte,e.created_at;
end $function$;

do $acl$begin if to_regprocedure('public.reporte_errores_preparacion_sede_v1(date,date,text)') is not null then execute 'revoke all on function public.reporte_errores_preparacion_sede_v1(date,date,text) from public,anon;';end if;end$acl$;

grant execute on function public.reporte_errores_preparacion_sede_v1(date,date,text) to authenticated;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v7(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v7(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_preparacion_v7(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_preparacion_v7(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_retirar_colaborador_actividad_v2(uuid,integer,uuid,text)') is not null then execute 'revoke all on function public.admin_retirar_colaborador_actividad_v2(uuid,integer,uuid,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_retirar_colaborador_actividad_v3(uuid,integer,uuid,text)') is not null then execute 'revoke all on function public.admin_retirar_colaborador_actividad_v3(uuid,integer,uuid,text) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_v8(uuid[],jsonb)') is not null then execute 'revoke all on function public.iniciar_actividad_v8(uuid[],jsonb) from public,anon,authenticated;';end if;end$acl$;

do $acl$begin if to_regprocedure('public.admin_actualizar_registro_historial_v2(text,uuid,jsonb,text)') is not null then execute 'revoke all on function public.admin_actualizar_registro_historial_v2(text,uuid,jsonb,text) from public,anon,authenticated;';end if;end$acl$;

create or replace function devoluciones_privado.puede_administrar_usuarios() returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('devoluciones','write')$$;

create or replace function devoluciones_privado.puede_gestionar_entrega(p_sede text) returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('devoluciones','write',p_sede)$$;

CREATE OR REPLACE FUNCTION public.actualizar_historial_sede_v1(p_tipo text, p_id uuid, p_cambios jsonb, p_motivo text, p_sede text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ant jsonb;nuevo jsonb;tid uuid;fac integer;lib numeric;act text;ids uuid[];nombres text[];principal uuid;comp text;em text;mn integer;mx integer;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;if length(trim(coalesce(p_motivo,'')))<3 then raise exception 'MOTIVO_REQUERIDO';end if;select email into em from auth.users where id=auth.uid();
 if p_tipo='preparacion' then
  select to_jsonb(h),h.timer_id into ant,tid from public.historial_preparaciones h where h.id=p_id and h.sede=s for update;if ant is null then raise exception 'REGISTRO_NO_ENCONTRADO';end if;fac=coalesce((p_cambios->>'facturas')::integer,0);lib=coalesce((p_cambios->>'libras')::numeric,-1);if fac<=0 or lib<0 then raise exception 'DATOS_INVALIDOS';end if;
  update public.historial_preparaciones set facturas=fac,libras=round(lib,2) where id=p_id and sede=s;update public.cronometros set datos=jsonb_set(jsonb_set(datos,'{facturas}',to_jsonb(fac),true),'{libras}',to_jsonb(round(lib,2)),true),actualizado_por=auth.uid(),actualizado_en=now(),version=version+1 where id=tid and sede=s;update public.preparacion_participaciones set facturas=fac,libras=round(lib,2),updated_at=now() where cronometro_id=tid and sede=s;select to_jsonb(h) into nuevo from public.historial_preparaciones h where h.id=p_id and h.sede=s;
 else
  select to_jsonb(h),h.timer_id into ant,tid from public.historial_actividades h where h.id=p_id and h.sede=s for update;if ant is null then raise exception 'REGISTRO_NO_ENCONTRADO';end if;act=trim(coalesce(p_cambios->>'actividad',''));select min_participantes,max_participantes into mn,mx from public.actividades_catalogo where sede=s and nombre=act;if mn is null then raise exception 'ACTIVIDAD_INVALIDA';end if;select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_cambios->'colaborador_ids','[]'::jsonb));if ids is null or cardinality(ids)<mn or (mx is not null and cardinality(ids)>mx) then raise exception 'CANTIDAD_PARTICIPANTES_INVALIDA';end if;select array_agg(c.nombre order by u.ord) into nombres from unnest(ids) with ordinality u(id,ord) join public.colaboradores c on c.id=u.id where c.sede=s and c.activo=true;if coalesce(cardinality(nombres),0)<>cardinality(ids) then raise exception 'COLABORADOR_INVALIDO_O_OTRA_SEDE';end if;principal=ids[1];comp=array_to_string(nombres,', ');
  update public.historial_actividades set colaborador_id=principal,empleado=comp,actividad=act,participantes=to_jsonb(nombres) where id=p_id and sede=s;update public.cronometros set colaborador_id=principal,empleado=comp,datos=jsonb_set(jsonb_set(jsonb_set(datos,'{actividad}',to_jsonb(act),true),'{participantes_ids}',to_jsonb(ids),true),'{participantes_nombres}',to_jsonb(nombres),true),actualizado_por=auth.uid(),actualizado_en=now(),version=version+1 where id=tid and sede=s;delete from public.actividad_participaciones where cronometro_id=tid and sede=s;insert into public.actividad_participaciones(cronometro_id,colaborador_id,colaborador_nombre,fecha,actividad,segundos_inicio,segundos_fin,segundos,estado,sede) select tid,c.id,c.nombre,h.fecha,act,0,h.segundos,h.segundos,'finalizado',s from public.historial_actividades h join unnest(ids) with ordinality u(id,ord) on true join public.colaboradores c on c.id=u.id where h.id=p_id and h.sede=s;select to_jsonb(h) into nuevo from public.historial_actividades h where h.id=p_id and h.sede=s;
 end if;
 insert into public.auditoria_modificaciones(tipo_registro,registro_id,timer_id,datos_anteriores,datos_nuevos,motivo,modificado_por,modificado_por_email,modificado_en,sede) values(p_tipo,p_id,tid,ant,nuevo,trim(p_motivo),auth.uid(),em,now(),s);return true;end $function$;

do $acl$begin if to_regprocedure('public.actualizar_historial_sede_v1(text,uuid,jsonb,text,text)') is not null then execute 'revoke all on function public.actualizar_historial_sede_v1(text,uuid,jsonb,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.actualizar_historial_sede_v1(text,uuid,jsonb,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.guardar_actividad_catalogo_sede_v1(p_id uuid, p_nombre text, p_min_participantes integer, p_max_participantes integer, p_orden integer, p_sede text)
 RETURNS actividades_catalogo
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.actividades_catalogo;v_ant text;s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 if length(trim(coalesce(p_nombre,'')))<3 then raise exception 'NOMBRE_ACTIVIDAD_INVALIDO'; end if;
 if p_min_participantes is null or p_min_participantes<1 then raise exception 'MINIMO_INVALIDO'; end if;
 if p_max_participantes is not null and p_max_participantes<p_min_participantes then raise exception 'MAXIMO_INVALIDO'; end if;
 if p_id is null then
  insert into public.actividades_catalogo(nombre,min_participantes,max_participantes,orden,activo,creado_por,actualizado_por,sede)
  values(trim(p_nombre),p_min_participantes,p_max_participantes,p_orden,true,auth.uid(),auth.uid(),s) returning * into v;
 else
  select nombre into v_ant from public.actividades_catalogo where id=p_id and sede=s for update;
  if v_ant is null then raise exception 'ACTIVIDAD_NO_ENCONTRADA'; end if;
  if v_ant<>trim(p_nombre) and (exists(select 1 from public.historial_actividades where sede=s and actividad=v_ant) or exists(select 1 from public.cronometros where sede=s and categoria='actividad' and datos->>'actividad'=v_ant)) then raise exception 'ACTIVIDAD_EN_USO_NO_RENOMBRAR'; end if;
  update public.actividades_catalogo set nombre=trim(p_nombre),min_participantes=p_min_participantes,max_participantes=p_max_participantes,orden=p_orden,actualizado_por=auth.uid(),updated_at=now() where id=p_id and sede=s returning * into v;
 end if; return v;
exception when unique_violation then raise exception 'ACTIVIDAD_DUPLICADA_EN_SEDE'; end $function$;

do $acl$begin if to_regprocedure('public.guardar_actividad_catalogo_sede_v1(uuid,text,integer,integer,integer,text)') is not null then execute 'revoke all on function public.guardar_actividad_catalogo_sede_v1(uuid,text,integer,integer,integer,text) from public,anon;';end if;end$acl$;

grant execute on function public.guardar_actividad_catalogo_sede_v1(uuid,text,integer,integer,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION public.finalizar_cronometro_sede_v1(p_id uuid, p_expected_version integer, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;tot integer;em text;parts jsonb;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;select * into v from public.cronometros where id=p_id and sede=s for update;if not found then raise exception 'NO_ENCONTRADO';end if;if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT';end if;if v.estado in('finalizado','cancelado') then raise exception 'YA_CERRADO';end if;
 tot=v.segundos_acumulados;if v.estado='ejecucion' and v.inicio is not null then tot=tot+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int);end if;select email into em from auth.users where id=auth.uid();
 if v.categoria='preparacion' then
  update public.preparacion_participaciones set segundos_fin=tot,segundos=greatest(0,tot-segundos_inicio),estado='finalizado',updated_at=now() where cronometro_id=v.id and sede=s and estado='activo';
  select coalesce(jsonb_agg(x.colaborador_nombre order by x.colaborador_nombre),'[]'::jsonb) into parts from(select distinct colaborador_nombre from public.preparacion_participaciones where cronometro_id=v.id and sede=s and estado='finalizado')x;
  insert into public.historial_preparaciones(timer_id,colaborador_id,fecha_preparacion,empleado,zona,tipo,facturas,libras,segundos,finalizado_por,finalizado_por_email,sede) values(v.id,v.colaborador_id,(v.datos->>'fecha_preparacion')::date,array_to_string(array(select jsonb_array_elements_text(parts)),', '),v.datos->>'zona',v.datos->>'tipo',(v.datos->>'facturas')::integer,coalesce((v.datos->>'libras')::numeric,0),tot,auth.uid(),em,s) on conflict(timer_id) do nothing;
 else
  update public.actividad_participaciones set segundos_fin=tot,segundos=greatest(0,tot-segundos_inicio),estado='finalizado',updated_at=now() where cronometro_id=v.id and sede=s and estado='activo';
  select coalesce(jsonb_agg(x.colaborador_nombre order by x.colaborador_nombre),'[]'::jsonb) into parts from(select distinct colaborador_nombre from public.actividad_participaciones where cronometro_id=v.id and sede=s and estado in('retirado','finalizado'))x;
  insert into public.historial_actividades(timer_id,colaborador_id,fecha,empleado,actividad,segundos,finalizado_por,finalizado_por_email,participantes,sede) values(v.id,v.colaborador_id,(v.datos->>'fecha')::date,array_to_string(array(select jsonb_array_elements_text(parts)),', '),v.datos->>'actividad',tot,auth.uid(),em,parts,s) on conflict(timer_id) do nothing;
 end if;
 update public.cronometros set estado='finalizado',inicio=null,segundos_acumulados=tot,version=version+1,actualizado_por=auth.uid(),actualizado_en=now(),finalizado_en=now() where id=p_id and sede=s returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.finalizar_cronometro_sede_v1(uuid,integer,text)') is not null then execute 'revoke all on function public.finalizar_cronometro_sede_v1(uuid,integer,text) from public,anon;';end if;end$acl$;

grant execute on function public.finalizar_cronometro_sede_v1(uuid,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION public.gestionar_cierre_sede_v1(p_fecha date, p_accion text, p_observacion text, p_sede text)
 RETURNS cierres_diarios
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cierres_diarios;em text;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_puede_cierre_sede(s) then raise exception 'SIN_PERMISO_CIERRE';end if;if p_accion not in('abrir','cerrar') then raise exception 'ACCION_INVALIDA';end if;select email into em from auth.users where id=auth.uid();
 if p_accion='cerrar' then if exists(select 1 from public.cronometros where sede=s and estado in('ejecucion','pausado') and coalesce(datos->>'fecha',datos->>'fecha_preparacion')=p_fecha::text) then raise exception 'EXISTEN_PROCESOS_ACTIVOS';end if;
  insert into public.cierres_diarios(fecha,observacion,cerrado_por,cerrado_por_email,cerrado_en,estado,reabierto_por,reabierto_por_email,reabierto_en,actualizado_en,sede) values(p_fecha,nullif(trim(coalesce(p_observacion,'')),''),auth.uid(),em,now(),'cerrado',null,null,null,now(),s)
  on conflict(sede,fecha) do update set observacion=excluded.observacion,cerrado_por=auth.uid(),cerrado_por_email=em,cerrado_en=now(),estado='cerrado',reabierto_por=null,reabierto_por_email=null,reabierto_en=null,actualizado_en=now() returning * into v;
 else
  insert into public.cierres_diarios(fecha,observacion,cerrado_por,cerrado_por_email,cerrado_en,estado,reabierto_por,reabierto_por_email,reabierto_en,actualizado_en,sede) values(p_fecha,nullif(trim(coalesce(p_observacion,'')),''),auth.uid(),em,now(),'abierto',auth.uid(),em,now(),now(),s)
  on conflict(sede,fecha) do update set estado='abierto',observacion=coalesce(excluded.observacion,public.cierres_diarios.observacion),reabierto_por=auth.uid(),reabierto_por_email=em,reabierto_en=now(),actualizado_en=now() returning * into v;
 end if;
 insert into public.auditoria_cierres_dia(fecha,accion,observacion,usuario_id,usuario_email,sede) values(p_fecha,p_accion,nullif(trim(coalesce(p_observacion,'')),''),auth.uid(),em,s);return v;end $function$;

do $acl$begin if to_regprocedure('public.gestionar_cierre_sede_v1(date,text,text,text)') is not null then execute 'revoke all on function public.gestionar_cierre_sede_v1(date,text,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.gestionar_cierre_sede_v1(date,text,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.guardar_colaborador_sede_v1(p_id uuid, p_nombre text, p_codigo text, p_sede text)
 RETURNS colaboradores
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.colaboradores; s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 if length(trim(coalesce(p_nombre,'')))<3 then raise exception 'NOMBRE_INVALIDO'; end if;
 if p_id is null then
   insert into public.colaboradores(nombre,codigo,sede) values(trim(p_nombre),nullif(trim(coalesce(p_codigo,'')),''),s) returning * into v;
 else
   if exists(select 1 from public.cronometros where sede=s and colaborador_id=p_id and estado in('ejecucion','pausado')) then raise exception 'NO_SE_PUEDE_EDITAR_CON_CRONOMETRO_ACTIVO'; end if;
   update public.colaboradores set nombre=trim(p_nombre),codigo=nullif(trim(coalesce(p_codigo,'')),''),updated_at=now() where id=p_id and sede=s returning * into v;
 end if;
 if v.id is null then raise exception 'COLABORADOR_NO_ENCONTRADO'; end if;
 return v;
exception when unique_violation then raise exception 'COLABORADOR_DUPLICADO_EN_SEDE'; end $function$;

do $acl$begin if to_regprocedure('public.guardar_colaborador_sede_v1(uuid,text,text,text)') is not null then execute 'revoke all on function public.guardar_colaborador_sede_v1(uuid,text,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.guardar_colaborador_sede_v1(uuid,text,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.guardar_ausencia_sede_v1(p_colaborador_id uuid, p_fecha date, p_horas_ausencia numeric, p_tipo_ausencia text, p_motivo text, p_sede text)
 RETURNS ausencias_personal
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n text;em text;j numeric;v public.ausencias_personal;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','catalogs',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;select nombre into n from public.colaboradores where id=p_colaborador_id and sede=s;if n is null then raise exception 'COLABORADOR_NO_ENCONTRADO';end if;j=public.horas_jornada_fecha(p_fecha);if j<=0 then raise exception 'DIA_SIN_JORNADA';end if;if p_horas_ausencia<=0 or p_horas_ausencia>j then raise exception 'HORAS_AUSENCIA_INVALIDAS';end if;select email into em from auth.users where id=auth.uid();
 insert into public.ausencias_personal(colaborador_id,colaborador_nombre,fecha,horas_ausencia,motivo,tipo_ausencia,registrado_por,registrado_por_email,updated_at,sede) values(p_colaborador_id,n,p_fecha,p_horas_ausencia,nullif(trim(coalesce(p_motivo,'')),''),coalesce(nullif(trim(p_tipo_ausencia),''),'Ausencia'),auth.uid(),em,now(),s)
 on conflict(colaborador_id,fecha) do update set horas_ausencia=excluded.horas_ausencia,motivo=excluded.motivo,tipo_ausencia=excluded.tipo_ausencia,registrado_por=auth.uid(),registrado_por_email=em,updated_at=now(),sede=s returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.guardar_ausencia_sede_v1(uuid,date,numeric,text,text,text)') is not null then execute 'revoke all on function public.guardar_ausencia_sede_v1(uuid,date,numeric,text,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.guardar_ausencia_sede_v1(uuid,date,numeric,text,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.guardar_metas_sede_v1(p_facturas_hora numeric, p_libras_hora numeric, p_productividad_minima numeric, p_actividad_alerta_min integer, p_sede text)
 RETURNS metas_productividad
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.metas_productividad;em text;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','delete',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if; if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;select email into em from auth.users where id=auth.uid();update public.metas_productividad set activo=false where sede=s and activo=true;insert into public.metas_productividad(facturas_hora,libras_hora,productividad_minima,actividad_alerta_min,activo,actualizado_por,actualizado_por_email,sede) values(p_facturas_hora,p_libras_hora,p_productividad_minima,p_actividad_alerta_min,true,auth.uid(),em,s) returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.guardar_metas_sede_v1(numeric,numeric,numeric,integer,text)') is not null then execute 'revoke all on function public.guardar_metas_sede_v1(numeric,numeric,numeric,integer,text) from public,anon;';end if;end$acl$;

grant execute on function public.guardar_metas_sede_v1(numeric,numeric,numeric,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION public.iniciar_preparacion_sede_v1(p_colaborador_ids uuid[], p_datos jsonb, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;ids uuid[];nombres text[];f date;idv uuid;nom text;s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 select array_agg(x order by x::text) into ids from(select distinct unnest(p_colaborador_ids)x)q;
 if ids is null or cardinality(ids)=0 then raise exception 'SIN_COLABORADORES'; end if;if cardinality(ids)<>cardinality(p_colaborador_ids) then raise exception 'COLABORADORES_DUPLICADOS'; end if;
 f:=coalesce((p_datos->>'fecha_preparacion')::date,current_date);
 if exists(select 1 from public.cierres_diarios where sede=s and fecha=f and estado='cerrado') then raise exception 'DIA_CERRADO'; end if;
 if trim(coalesce(p_datos->>'zona',''))='' or trim(coalesce(p_datos->>'tipo',''))='' then raise exception 'DATOS_PREPARACION_INCOMPLETOS'; end if;
 if coalesce((p_datos->>'facturas')::integer,0)<=0 then raise exception 'FACTURAS_INVALIDAS'; end if;
 select array_agg(c.nombre order by u.ord) into nombres from unnest(ids) with ordinality u(id,ord) join public.colaboradores c on c.id=u.id where c.sede=s and c.activo=true;
 if coalesce(cardinality(nombres),0)<>cardinality(ids) then raise exception 'COLABORADOR_INVALIDO_O_OTRA_SEDE'; end if;
 perform pg_advisory_xact_lock(hashtextextended(x::text,0)) from unnest(ids)x order by x::text;
 if exists(select 1 from public.cronometros c where c.sede=s and c.estado in('ejecucion','pausado') and exists(select 1 from unnest(ids) z where z=c.colaborador_id or z::text in(select value from jsonb_array_elements_text(coalesce(c.datos->'participantes_ids','[]'::jsonb))))) then raise exception 'COLABORADOR_OCUPADO'; end if;
 p_datos:=jsonb_set(jsonb_set(jsonb_set(p_datos,'{sede}',to_jsonb(s),true),'{participantes_ids}',to_jsonb(ids),true),'{participantes_nombres}',to_jsonb(nombres),true);
 insert into public.cronometros(categoria,empleado,colaborador_id,estado,inicio,segundos_acumulados,datos,version,iniciado_por,actualizado_por,actualizado_en,sede)
 values('preparacion',array_to_string(nombres,', '),ids[1],'ejecucion',now(),0,p_datos,1,auth.uid(),auth.uid(),now(),s) returning * into v;
 foreach idv in array ids loop select nombre into nom from public.colaboradores where id=idv and sede=s; insert into public.preparacion_participaciones(cronometro_id,colaborador_id,colaborador_nombre,fecha,zona,tipo,facturas,libras,segundos_inicio,segundos,estado,sede) values(v.id,idv,nom,f,p_datos->>'zona',p_datos->>'tipo',(p_datos->>'facturas')::integer,coalesce((p_datos->>'libras')::numeric,0),0,0,'activo',s); end loop;
 return v;end $function$;

do $acl$begin if to_regprocedure('public.iniciar_preparacion_sede_v1(uuid[],jsonb,text)') is not null then execute 'revoke all on function public.iniciar_preparacion_sede_v1(uuid[],jsonb,text) from public,anon;';end if;end$acl$;

grant execute on function public.iniciar_preparacion_sede_v1(uuid[],jsonb,text) to authenticated;

CREATE OR REPLACE FUNCTION public.iniciar_actividad_sede_v1(p_colaborador_ids uuid[], p_datos jsonb, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;ids uuid[];nombres text[];f date;act text;mn integer;mx integer;idv uuid;nom text;s text:=upper(p_sede);
begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 select array_agg(x order by x::text) into ids from(select distinct unnest(p_colaborador_ids)x)q;if ids is null or cardinality(ids)=0 then raise exception 'SIN_COLABORADORES'; end if;if cardinality(ids)<>cardinality(p_colaborador_ids) then raise exception 'COLABORADORES_DUPLICADOS'; end if;
 f:=coalesce((p_datos->>'fecha')::date,current_date);act:=trim(coalesce(p_datos->>'actividad',''));if act='' then raise exception 'ACTIVIDAD_REQUERIDA'; end if;
 select min_participantes,max_participantes into mn,mx from public.actividades_catalogo where sede=s and nombre=act and activo=true;if mn is null then raise exception 'ACTIVIDAD_INVALIDA_O_INACTIVA'; end if;if cardinality(ids)<mn then raise exception 'MINIMO_PARTICIPANTES_%',mn;end if;if mx is not null and cardinality(ids)>mx then raise exception 'MAXIMO_PARTICIPANTES_%',mx;end if;
 if exists(select 1 from public.cierres_diarios where sede=s and fecha=f and estado='cerrado') then raise exception 'DIA_CERRADO'; end if;
 select array_agg(c.nombre order by u.ord) into nombres from unnest(ids) with ordinality u(id,ord) join public.colaboradores c on c.id=u.id where c.sede=s and c.activo=true;if coalesce(cardinality(nombres),0)<>cardinality(ids) then raise exception 'COLABORADOR_INVALIDO_O_OTRA_SEDE';end if;
 perform pg_advisory_xact_lock(hashtextextended(x::text,0)) from unnest(ids)x order by x::text;
 if exists(select 1 from public.cronometros c where c.sede=s and c.estado in('ejecucion','pausado') and exists(select 1 from unnest(ids) z where z=c.colaborador_id or z::text in(select value from jsonb_array_elements_text(coalesce(c.datos->'participantes_ids','[]'::jsonb))))) then raise exception 'COLABORADOR_OCUPADO';end if;
 p_datos:=jsonb_set(jsonb_set(jsonb_set(p_datos,'{sede}',to_jsonb(s),true),'{participantes_ids}',to_jsonb(ids),true),'{participantes_nombres}',to_jsonb(nombres),true);
 insert into public.cronometros(categoria,empleado,colaborador_id,estado,inicio,segundos_acumulados,datos,version,iniciado_por,actualizado_por,actualizado_en,sede) values('actividad',array_to_string(nombres,', '),ids[1],'ejecucion',now(),0,p_datos,1,auth.uid(),auth.uid(),now(),s) returning * into v;
 foreach idv in array ids loop select nombre into nom from public.colaboradores where id=idv and sede=s;insert into public.actividad_participaciones(cronometro_id,colaborador_id,colaborador_nombre,fecha,actividad,segundos_inicio,segundos,estado,sede) values(v.id,idv,nom,f,act,0,0,'activo',s);end loop;
 return v;end $function$;

do $acl$begin if to_regprocedure('public.iniciar_actividad_sede_v1(uuid[],jsonb,text)') is not null then execute 'revoke all on function public.iniciar_actividad_sede_v1(uuid[],jsonb,text) from public,anon;';end if;end$acl$;

grant execute on function public.iniciar_actividad_sede_v1(uuid[],jsonb,text) to authenticated;

CREATE OR REPLACE FUNCTION public.reanudar_cronometro_sede_v1(p_id uuid, p_expected_version integer, p_sede text)
 RETURNS cronometros
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v public.cronometros;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;select * into v from public.cronometros where id=p_id and sede=s for update;if not found then raise exception 'NO_ENCONTRADO';end if;if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT';end if;if v.estado<>'pausado' then raise exception 'ESTADO_INVALIDO';end if;
 update public.pausas_cronometros set reanudado_en=now() where id=(select id from public.pausas_cronometros where cronometro_id=p_id and sede=s and reanudado_en is null order by pausado_en desc limit 1);
 update public.cronometros set estado='ejecucion',inicio=now(),version=version+1,actualizado_por=auth.uid(),actualizado_en=now() where id=p_id and sede=s returning * into v;return v;end $function$;

do $acl$begin if to_regprocedure('public.reanudar_cronometro_sede_v1(uuid,integer,text)') is not null then execute 'revoke all on function public.reanudar_cronometro_sede_v1(uuid,integer,text) from public,anon;';end if;end$acl$;

grant execute on function public.reanudar_cronometro_sede_v1(uuid,integer,text) to authenticated;

create or replace function devoluciones_privado.autorizado() returns boolean language sql stable security definer set search_path='' as $$select public.bia_can('devoluciones','read')$$;

CREATE OR REPLACE FUNCTION public.eliminar_historial_sede_v1(p_tipo text, p_id uuid, p_motivo text, p_sede text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d jsonb;em text;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','delete',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if; if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;if length(trim(coalesce(p_motivo,'')))<5 then raise exception 'MOTIVO_REQUERIDO';end if;select email into em from auth.users where id=auth.uid();if p_tipo='preparacion' then select to_jsonb(h) into d from public.historial_preparaciones h where h.id=p_id and h.sede=s for update;if d is null then raise exception 'REGISTRO_NO_ENCONTRADO';end if;insert into public.auditoria_eliminaciones(tipo_registro,registro_id,datos_eliminados,motivo,eliminado_por,eliminado_por_email,sede) values(p_tipo,p_id,d,trim(p_motivo),auth.uid(),em,s);delete from public.historial_preparaciones where id=p_id and sede=s;elsif p_tipo='actividad' then select to_jsonb(h) into d from public.historial_actividades h where h.id=p_id and h.sede=s for update;if d is null then raise exception 'REGISTRO_NO_ENCONTRADO';end if;insert into public.auditoria_eliminaciones(tipo_registro,registro_id,datos_eliminados,motivo,eliminado_por,eliminado_por_email,sede) values(p_tipo,p_id,d,trim(p_motivo),auth.uid(),em,s);delete from public.historial_actividades where id=p_id and sede=s;else raise exception 'TIPO_INVALIDO';end if;return jsonb_build_object('ok',true,'sede',s,'id',p_id);end $function$;

do $acl$begin if to_regprocedure('public.eliminar_historial_sede_v1(text,uuid,text,text)') is not null then execute 'revoke all on function public.eliminar_historial_sede_v1(text,uuid,text,text) from public,anon;';end if;end$acl$;

grant execute on function public.eliminar_historial_sede_v1(text,uuid,text,text) to authenticated;

do $acl$begin if to_regprocedure('public.dev_admin_vincular_usuario(uuid,text,text,text,text,text)') is not null then execute 'revoke all on function public.dev_admin_vincular_usuario(uuid,text,text,text,text,text) from public,anon,authenticated;';end if;end$acl$;

CREATE OR REPLACE FUNCTION devoluciones_privado.agregar_catalogo(p_tipo text, p_nombre text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_nombre text:=regexp_replace(trim(coalesce(p_nombre,'')),'[[:space:]]+',' ','g'); v_existente text;
begin
 if not public.bia_can('devoluciones','write') then raise exception 'SOLO_LECTURA';end if;
 if auth.uid() is null or not devoluciones_privado.autorizado() or not exists(select 1 from public.sedes s where public.usuario_puede_sede(s.codigo)) then raise exception 'No tienes acceso para agregar registros.'; end if;
 if p_tipo is null or p_tipo not in ('cliente','comentario') then raise exception 'Tipo de catálogo no válido.'; end if;
 if length(v_nombre) not between 1 and 200 then raise exception 'Escribe entre 1 y 200 caracteres.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('dev_catalogo:'||p_tipo,0));
 if p_tipo='cliente' then
  select nombre into v_existente from public.negocio where lower(nombre)=lower(v_nombre) order by nombre limit 1;
  if v_existente is not null then return v_existente; end if;
  insert into public.negocio(nombre) values(v_nombre);
 else
  select nombre into v_existente from public.observaciones where lower(nombre)=lower(v_nombre) order by nombre limit 1;
  if v_existente is not null then return v_existente; end if;
  insert into public.observaciones(nombre) values(v_nombre);
 end if;
 return v_nombre;
end $function$;

drop policy if exists intranet_scope on public.cronometros;

create policy intranet_scope on public.cronometros as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.colaboradores;

create policy intranet_scope on public.colaboradores as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.actividades_catalogo;

create policy intranet_scope on public.actividades_catalogo as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.historial_preparaciones;

create policy intranet_scope on public.historial_preparaciones as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.historial_actividades;

create policy intranet_scope on public.historial_actividades as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.ausencias_personal;

create policy intranet_scope on public.ausencias_personal as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.metas_productividad;

create policy intranet_scope on public.metas_productividad as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.cierres_diarios;

create policy intranet_scope on public.cierres_diarios as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.auditoria_cierres_dia;

create policy intranet_scope on public.auditoria_cierres_dia as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.pausas_cronometros;

create policy intranet_scope on public.pausas_cronometros as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.auditoria_modificaciones;

create policy intranet_scope on public.auditoria_modificaciones as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.auditoria_eliminaciones;

create policy intranet_scope on public.auditoria_eliminaciones as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.preparacion_participaciones;

create policy intranet_scope on public.preparacion_participaciones as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.actividad_participaciones;

create policy intranet_scope on public.actividad_participaciones as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.errores_preparacion;

create policy intranet_scope on public.errores_preparacion as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.errores_preparacion_participantes;

create policy intranet_scope on public.errores_preparacion_participantes as restrictive for all to authenticated using(public.bia_can('tiempos','read',sede)) with check(public.bia_can('tiempos','write',sede));

drop policy if exists intranet_scope on public.devoluciones;

create policy intranet_scope on public.devoluciones as restrictive for all to authenticated using(public.bia_can('devoluciones','read',sede)) with check(public.bia_can('devoluciones','write',sede));

drop policy if exists intranet_scope on public.devoluciones_entregas;

create policy intranet_scope on public.devoluciones_entregas as restrictive for all to authenticated using(public.bia_can('devoluciones','read',sede)) with check(public.bia_can('devoluciones','write',sede));

drop policy if exists "Administrador elimina reclamos" on public.supplier_claims;

create policy "Administrador elimina reclamos" on public.supplier_claims for DELETE to authenticated using (public.bia_can('contenedores','delete',agency)) ;

drop policy if exists "Operadores actualizan reclamos" on public.supplier_claims;

create policy "Operadores actualizan reclamos" on public.supplier_claims for UPDATE to authenticated using (public.bia_can('contenedores','write',agency)) with check (public.bia_can('contenedores','write',agency));

drop policy if exists "Operadores crean reclamos" on public.supplier_claims;

create policy "Operadores crean reclamos" on public.supplier_claims for INSERT to authenticated with check (public.bia_can('contenedores','write',agency) and created_by=auth.uid());

drop policy if exists "Usuarios activos consultan reclamos" on public.supplier_claims;

create policy "Usuarios activos consultan reclamos" on public.supplier_claims for SELECT to authenticated using (public.bia_can('contenedores','read',agency)) ;

drop policy if exists intranet_evidence on storage.objects;create policy intranet_evidence on storage.objects as restrictive for all to authenticated using(bucket_id<>'evidencias' or (public.bia_can('contenedores','read') and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.supplier_claims c where public.bia_can('contenedores','read',c.agency) and (c.container_photos::text like '%'||name||'%' or c.damage_photos::text like '%'||name||'%'))))) with check(bucket_id<>'evidencias' or public.bia_can('contenedores','write'));

drop policy if exists intranet_evidence_insert on storage.objects;

create policy intranet_evidence_insert on storage.objects as restrictive for INSERT to authenticated with check (bucket_id<>'evidencias' or public.bia_can('contenedores','write'));

drop policy if exists intranet_evidence_update on storage.objects;

create policy intranet_evidence_update on storage.objects as restrictive for UPDATE to authenticated using (bucket_id<>'evidencias' or public.bia_can('contenedores','write')) with check (bucket_id<>'evidencias' or public.bia_can('contenedores','write'));

drop policy if exists intranet_evidence_delete on storage.objects;

create policy intranet_evidence_delete on storage.objects as restrictive for DELETE to authenticated using (bucket_id<>'evidencias' or public.bia_can('contenedores','write')) ;

drop policy if exists intranet_sku_select on public.codigos;

create policy intranet_sku_select on public.codigos as restrictive for SELECT to authenticated using (public.bia_can('contenedores','read') or public.bia_can('devoluciones','read')) ;

drop policy if exists intranet_sku_insert on public.codigos;

create policy intranet_sku_insert on public.codigos as restrictive for INSERT to authenticated with check (public.bia_can('contenedores','write') or public.bia_can('devoluciones','write'));

drop policy if exists intranet_sku_update on public.codigos;

create policy intranet_sku_update on public.codigos as restrictive for UPDATE to authenticated using (public.bia_can('contenedores','write') or public.bia_can('devoluciones','write')) with check (public.bia_can('contenedores','write') or public.bia_can('devoluciones','write'));

drop policy if exists intranet_sku_delete on public.codigos;

create policy intranet_sku_delete on public.codigos as restrictive for DELETE to authenticated using (public.bia_can('contenedores','write') or public.bia_can('devoluciones','write')) ;

do $acl$begin if to_regprocedure('public.admin_eliminar_usuario_completo_v1(uuid,uuid,text,jsonb,boolean)') is not null then execute 'revoke all on function public.admin_eliminar_usuario_completo_v1(uuid,uuid,text,jsonb,boolean) from public,anon,authenticated,service_role;';end if;end$acl$;

notify pgrst,'reload schema';
