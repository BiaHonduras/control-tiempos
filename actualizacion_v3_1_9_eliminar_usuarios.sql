-- Eliminación atómica con traspaso por sede. Solo la Edge Function autenticada
-- puede llamar las RPC; nunca se permite que el navegador suplante al solicitante.
create schema if not exists control_tiempos_privado;
revoke all on schema control_tiempos_privado from public, anon, authenticated;
grant usage on schema control_tiempos_privado to service_role;
create table if not exists control_tiempos_privado.traspasos_usuarios (
 id uuid primary key default gen_random_uuid(), fecha timestamptz not null default now(),
 origen_id uuid not null, origen_email text not null, solicitado_por uuid not null,
 solicitado_por_email text not null, receptores jsonb not null, registros jsonb not null
);
alter table control_tiempos_privado.traspasos_usuarios enable row level security;
revoke all on control_tiempos_privado.traspasos_usuarios from public, anon, authenticated;

create or replace function control_tiempos_privado.gestionar_eliminacion_usuario(
 p_actor uuid, p_usuario uuid, p_sede text, p_receptores jsonb default null, p_confirmado boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_email text; v_actor_email text; v_maestro boolean; v_sedes text[]; v_s text;
 v_plan jsonb:='[]'; v_opciones jsonb; v_destino uuid; v_destino_email text;
 v_registros jsonb:='{}'; v_receptores jsonb:='{}'; v_n bigint; v_r record; v_t text; v_c text; v_ec text;
 v_tablas text[]:=array['cronometros','historial_preparaciones','historial_actividades',
 'auditoria_eliminaciones','auditoria_modificaciones','ausencias_personal','errores_preparacion',
 'metas_productividad','pausas_cronometros','cierres_diarios','auditoria_cierres_dia',
 'actividad_participaciones','actividades_catalogo','vencimientos_semanales','supplier_claims'];
begin
 if p_actor is null or p_usuario is null then raise exception 'AUTH_REQUIRED'; end if;
 select email into v_actor_email from auth.users where id=p_actor
 and coalesce(raw_app_meta_data->>'must_change_password','false')<>'true';
 if not found then raise exception 'AUTH_REQUIRED'; end if;
 v_maestro:=lower(v_actor_email) in ('javierh@biabrands.co','fesicars@gmail.com');
 -- Serializa eliminaciones y cambios de accesos para revalidar el mínimo de usuarios.
 lock table public.usuarios_sedes in share row exclusive mode;
 select email into v_email from auth.users where id=p_usuario for update;
 if not found then raise exception 'USUARIO_NO_EXISTE'; end if;
 if not exists(select 1 from public.usuarios_sedes where user_id=p_usuario and sede=upper(p_sede))
 then raise exception 'USUARIO_FUERA_DE_SEDE'; end if;
 if lower(v_email) in ('javierh@biabrands.co','fesicars@gmail.com') and not v_maestro
 then raise exception 'SOLO_USUARIO_MAESTRO'; end if;
 if exists(select 1 from public.usuarios where auth_user_id=p_usuario and activo)
 then raise exception 'CUENTA_OTROS_MODULOS: Esta cuenta tiene acceso activo al módulo de inventarios. Desactive ese acceso antes de eliminarla por completo.'; end if;
 select array_agg(distinct sede order by sede) into v_sedes from public.usuarios_sedes where user_id=p_usuario;
 -- Incluye sedes con registros históricos aunque el acceso ya se haya retirado.
 foreach v_t in array v_tablas loop
  execute format('lock table public.%I in share row exclusive mode',v_t);
  for v_c in select c.column_name from information_schema.columns c where c.table_schema='public'
    and c.table_name=v_t and c.data_type='uuid' and c.column_name in
    ('iniciado_por','actualizado_por','finalizado_por','eliminado_por','modificado_por','registrado_por',
     'pausado_por','cerrado_por','reabierto_por','usuario_id','retirado_por','creado_por','user_id','created_by') loop
   execute format('select to_jsonb(array_agg(distinct upper(%I))) from public.%I where %I=$1',
     case when v_t='supplier_claims' then 'agency' else 'sede' end,v_t,v_c) into v_opciones using p_usuario;
   -- Se obtiene un JSON array para tratar columnas sede y agency del mismo modo.
   if v_opciones is not null then
    for v_s in select jsonb_array_elements_text(v_opciones) loop
     if v_s is null or v_s not in('SPS','CBA','SRC') then raise exception 'SEDE_DE_REGISTROS_NO_COMPATIBLE'; end if;
     if not(v_s=any(v_sedes)) then v_sedes:=array_append(v_sedes,v_s); end if;
    end loop;
   end if;
  end loop;
 end loop;
 foreach v_s in array v_sedes loop
  if not v_maestro and not exists(select 1 from public.usuarios_sedes where user_id=p_actor and sede=v_s and activo and rol='admin')
  then raise exception 'SOLO_ADMINISTRADOR_SEDE: Necesita permiso de administrador en % para eliminar esta cuenta completa.',v_s; end if;
  select jsonb_agg(jsonb_build_object('user_id',us.user_id,'email',a.email,'nombre',us.nombre,'rol',us.rol) order by a.email)
   into v_opciones from public.usuarios_sedes us join auth.users a on a.id=us.user_id
   where us.sede=v_s and us.activo and us.user_id<>p_usuario;
  if v_opciones is null then raise exception 'SIN_OTRO_USUARIO: No se puede eliminar. Debe existir al menos otro usuario activo en la sede % para recibir sus gestiones.',v_s; end if;
  if exists(select 1 from public.usuarios_sedes where user_id=p_usuario and sede=v_s and activo and rol='admin')
   and not exists(select 1 from public.usuarios_sedes where user_id<>p_usuario and sede=v_s and activo and rol='admin')
   and not exists(select 1 from auth.users where id<>p_usuario and lower(email) in('javierh@biabrands.co','fesicars@gmail.com') and coalesce(raw_app_meta_data->>'must_change_password','false')<>'true')
  then raise exception 'ULTIMO_ADMINISTRADOR: Asigne otro administrador en % antes de eliminar esta cuenta.',v_s; end if;
  v_plan:=v_plan||jsonb_build_array(jsonb_build_object('sede',v_s,'usuarios',v_opciones));
 end loop;
 if p_receptores is null then return jsonb_build_object('ok',true,'usuario_id',p_usuario,'email',v_email,'sedes',v_plan); end if;
 if p_confirmado is distinct from true then raise exception 'CONFIRMACION_REQUERIDA'; end if;
 if jsonb_typeof(p_receptores)<>'object' then raise exception 'RECEPTORES_INVALIDOS'; end if;
 foreach v_s in array v_sedes loop
  v_destino:=nullif(p_receptores->>v_s,'')::uuid;
  select a.email into v_destino_email from public.usuarios_sedes us join auth.users a on a.id=us.user_id
   where us.sede=v_s and us.activo and us.user_id=v_destino and us.user_id<>p_usuario;
  if not found then raise exception 'RECEPTOR_INVALIDO: Seleccione otro usuario activo de la sede %.',v_s; end if;
  v_receptores:=v_receptores||jsonb_build_object(v_s,jsonb_build_object('user_id',v_destino,'email',v_destino_email));
 end loop;
 -- Reasigna cada relación y su correo, conservando fechas, datos y totales.
 foreach v_t in array v_tablas loop
  for v_c in select c.column_name from information_schema.columns c where c.table_schema='public'
    and c.table_name=v_t and c.data_type='uuid' and c.column_name in
    ('iniciado_por','actualizado_por','finalizado_por','eliminado_por','modificado_por','registrado_por',
     'pausado_por','cerrado_por','reabierto_por','usuario_id','retirado_por','creado_por','user_id','created_by') loop
   v_ec:=case when v_c='usuario_id' then 'usuario_email' else v_c||'_email' end;
   if not exists(select 1 from information_schema.columns where table_schema='public' and table_name=v_t and column_name=v_ec) then v_ec:=null; end if;
   foreach v_s in array v_sedes loop
    v_destino:=(v_receptores->v_s->>'user_id')::uuid; v_destino_email:=v_receptores->v_s->>'email';
    execute format('update public.%I set %I=$2%s where %I=$1 and upper(%I)=$4',v_t,v_c,
      case when v_ec is null then '' else format(', %I=$3',v_ec) end,v_c,
      case when v_t='supplier_claims' then 'agency' else 'sede' end)
      using p_usuario,v_destino,v_destino_email,v_s;
    get diagnostics v_n=row_count;
    if v_n>0 then v_registros:=v_registros||jsonb_build_object(v_t||'.'||v_c||'.'||v_s,v_n); end if;
   end loop;
  end loop;
 end loop;
 -- Abortamos ante referencias nuevas no contempladas, en vez de perderlas por CASCADE/SET NULL.
 for v_r in select n.nspname schema_name,t.relname tabla,a.attname columna from pg_catalog.pg_constraint c
  join pg_catalog.pg_class t on t.oid=c.conrelid join pg_catalog.pg_namespace n on n.oid=t.relnamespace
  join pg_catalog.pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
  where c.contype='f' and c.confrelid='auth.users'::regclass and n.nspname<>'auth'
   and not(n.nspname='public' and t.relname in('perfiles','user_profiles','usuarios_sedes')) loop
  execute format('select count(*) from %I.%I where %I=$1',v_r.schema_name,v_r.tabla,v_r.columna) into v_n using p_usuario;
  if v_n>0 then raise exception 'REFERENCIAS_SIN_TRASPASAR: %.%',v_r.tabla,v_r.columna; end if;
 end loop;
 insert into control_tiempos_privado.traspasos_usuarios(origen_id,origen_email,solicitado_por,solicitado_por_email,receptores,registros)
  values(p_usuario,v_email,p_actor,v_actor_email,v_receptores,v_registros);
 -- Evita credenciales independientes residuales de inventarios si existía un vínculo inactivo.
 delete from public.usuarios where auth_user_id=p_usuario;
 -- Una sola transacción: auth elimina también sesiones, identidades y perfiles vinculados.
 -- Si cualquier dependencia falla, PostgreSQL revierte también todos los traspasos.
 delete from auth.users where id=p_usuario;
 return jsonb_build_object('ok',true,'deleted',true,'email',v_email,'receptores',v_receptores,'registros',v_registros);
end $$;
revoke all on function control_tiempos_privado.gestionar_eliminacion_usuario(uuid,uuid,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function control_tiempos_privado.gestionar_eliminacion_usuario(uuid,uuid,text,jsonb,boolean) to service_role;
create or replace function public.admin_eliminar_usuario_completo_v1(
 p_actor uuid,p_usuario uuid,p_sede text,p_receptores jsonb default null,p_confirmado boolean default false
) returns jsonb language sql security invoker set search_path='' as $$
 select control_tiempos_privado.gestionar_eliminacion_usuario(p_actor,p_usuario,p_sede,p_receptores,p_confirmado);
$$;
revoke all on function public.admin_eliminar_usuario_completo_v1(uuid,uuid,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.admin_eliminar_usuario_completo_v1(uuid,uuid,text,jsonb,boolean) to service_role;
notify pgrst,'reload schema';
