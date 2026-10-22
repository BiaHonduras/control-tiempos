-- Administradores: acceso a todas las sedes sin elevar a usuario maestro.
create or replace function public.usuario_es_admin_global() returns boolean
language sql stable security definer set search_path = '' as $$
 select public.usuario_password_actualizada() and (public.usuario_es_maestro() or exists(
 select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.activo and s.rol='admin'));
$$;
revoke all on function public.usuario_es_admin_global() from public,anon;
grant execute on function public.usuario_es_admin_global() to authenticated;
create or replace function public.usuario_es_admin_sede(p_sede text) returns boolean
language sql stable security definer set search_path = '' as $$
 select upper(p_sede)=any(array['SPS','CBA','SRC','TGU','AMT']) and public.usuario_es_admin_global();
$$;
create or replace function public.usuario_puede_sede(p_sede text) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.usuario_password_actualizada() and upper(p_sede)=any(array['SPS','CBA','SRC','TGU','AMT']) and
 (public.usuario_es_admin_global() or exists(select 1 from public.usuarios_sedes s
 where s.user_id=auth.uid() and s.sede=upper(p_sede) and s.activo));
$$;
create or replace function public.obtener_sedes_usuario() returns text[]
language sql stable security definer set search_path = '' as $$
 select case when not public.usuario_password_actualizada() then array[]::text[]
 when public.usuario_es_admin_global() then array['SPS','CBA','SRC','TGU','AMT']::text[]
 else array(select s.sede from public.usuarios_sedes s where s.user_id=auth.uid() and s.activo
 and s.sede=any(array['SPS','CBA','SRC','TGU','AMT']) order by s.sede) end;
$$;

CREATE OR REPLACE FUNCTION public.obtener_acceso_sede(p_sede text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v record; v_sedes text[]; v_master boolean;
begin
 v_master:=public.usuario_es_maestro();
 v_sedes:=public.obtener_sedes_usuario();
 select * into v from public.usuarios_sedes where user_id=auth.uid() and sede=upper(p_sede) and activo=true;
 return jsonb_build_object(
   'permitido',public.usuario_puede_sede(p_sede),
   'es_maestro',v_master,
   'rol',case when public.usuario_es_admin_sede(p_sede) then 'admin' else coalesce(v.rol,'consulta') end,
   'puede_cierre_dia',public.usuario_puede_sede(p_sede) and (public.usuario_es_admin_sede(p_sede) or coalesce(v.puede_cierre_dia,false)),
   'sedes',to_jsonb(v_sedes)
 );
end $function$;

CREATE OR REPLACE FUNCTION public.bia_profile(p_sede text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.usuarios_sedes; a auth.users; v_master boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into a from auth.users where id=auth.uid();
 if not public.usuario_password_actualizada() then raise exception 'CAMBIO_PASSWORD_REQUERIDO'; end if;
 v_master:=public.usuario_es_maestro();
 select * into s from public.usuarios_sedes where user_id=auth.uid()
 order by activo desc,(sede=upper(coalesce(p_sede,''))) desc,case sede when 'SPS' then 0 else 1 end,sede limit 1;
 return jsonb_build_object('id',a.id,'email',a.email,'full_name',coalesce(s.nombre,a.raw_user_meta_data->>'nombre',a.raw_user_meta_data->>'full_name',''),
 'nombre_corto',coalesce((select nullif(trim(u.nombre_corto),'') from public.usuarios u where u.auth_user_id=auth.uid() and u.activo limit 1),'Sin nombre corto'),'is_admin',public.usuario_es_admin_global(),'employee_code','','role',case when public.usuario_es_admin_global() then 'admin' else coalesce(s.rol,'consulta') end,
 'agency',coalesce(s.sede,'SPS'),'is_active',v_master or coalesce(s.activo,false),
 'is_master',v_master,'sedes',public.obtener_sedes_usuario(),'created_at',a.created_at,'updated_at',s.updated_at);
end $function$;

CREATE OR REPLACE FUNCTION devoluciones_privado.modificar_gestion(p_id uuid, p_version integer, p_datos jsonb, p_items jsonb, p_eliminar boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.devoluciones; v_actor text; v_item jsonb; v_before jsonb; v_after jsonb; v_count integer; v_changes text; v_quantities text;
begin
 if auth.uid() is null or not devoluciones_privado.autorizado() then raise exception 'Inicia sesión para continuar'; end if;
 select * into v from public.devoluciones where id=p_id and eliminado_at is null for update;
 if not found then raise exception 'Gestión no encontrada o eliminada'; end if;
 if not public.usuario_puede_sede(v.sede) or not (public.usuario_es_admin_sede(v.sede) or exists(select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.sede=v.sede and s.activo and s.rol in ('admin','operador'))) then raise exception 'Sin permiso para modificar esta gestión'; end if;
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

CREATE OR REPLACE FUNCTION devoluciones_privado.puede_gestionar_entrega(p_sede text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select devoluciones_privado.autorizado() and public.usuario_puede_sede(p_sede) and
 (public.usuario_es_admin_sede(p_sede) or exists(select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.sede=p_sede and s.activo and s.rol in ('admin','operador')));
$function$;


alter policy "Operadores actualizan reclamos" on public.supplier_claims
using (public.usuario_password_actualizada() and (public.usuario_es_admin_sede(agency) or exists(select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.sede=agency and s.activo and s.rol='operador')))
with check (public.usuario_password_actualizada() and (public.usuario_es_admin_sede(agency) or exists(select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.sede=agency and s.activo and s.rol='operador')));
alter policy "Operadores crean reclamos" on public.supplier_claims
with check (created_by=auth.uid() and public.usuario_password_actualizada() and (public.usuario_es_admin_sede(agency) or exists(select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.sede=agency and s.activo and s.rol='operador')));

create or replace function public.usuario_puede_cierre_sede(p_sede text) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.usuario_puede_sede(p_sede) and (public.usuario_es_admin_sede(p_sede) or exists(
 select 1 from public.usuarios_sedes s where s.user_id=auth.uid() and s.sede=upper(p_sede) and s.activo and s.puede_cierre_dia));
$$;
CREATE OR REPLACE FUNCTION devoluciones_privado.crear(p_datos jsonb, p_items jsonb, p_solicitud uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid; v_gestion text; v_n integer; v_item jsonb; v_cod jsonb; v_fecha date := (now() at time zone 'America/Tegucigalpa')::date;
begin
 if not devoluciones_privado.autorizado() or not devoluciones_privado.puede_gestionar_entrega(p_datos->>'sede') then raise exception 'Sin acceso a esta sede'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_solicitud::text,0));
 select id,gestion into v_id,v_gestion from public.devoluciones where solicitud_id=p_solicitud and creado_por=auth.uid();
 if found then return jsonb_build_object('id',v_id,'gestion',v_gestion); end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Agregue los códigos'; end if; if jsonb_array_length(p_items) not between 1 and 200 then raise exception 'Agregue entre 1 y 200 códigos'; end if;
 if not exists(select 1 from public.usuarios where id=(p_datos->>'gestor_n1')::integer and activo is true) then raise exception 'Gestor no válido'; end if;
 insert into devoluciones_privado.consecutivos values(v_fecha,1) on conflict(fecha) do update set numero=devoluciones_privado.consecutivos.numero+1 returning numero into v_n;
 v_gestion:='DEV-'||to_char(v_fecha,'DDMMYYYY')||'-'||case when v_n<10 then '0'||v_n::text else v_n::text end;
 insert into public.devoluciones(solicitud_id,gestion,sede,gestor_n1,factura,cliente,observacion,bodega_origen,bodega_destino,comentario,creado_por)
 values(p_solicitud,v_gestion,p_datos->>'sede',(p_datos->>'gestor_n1')::integer,trim(p_datos->>'factura'),p_datos->>'cliente',p_datos->>'observacion',trim(p_datos->>'bodega_origen'),trim(p_datos->>'bodega_destino'),coalesce(p_datos->>'comentario',''),auth.uid()) returning id into v_id;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_cod:=devoluciones_privado.codigo(v_item->>'codigo');
  insert into public.devoluciones_detalle(devolucion_id,codigo,descripcion,cantidad,costo_unitario) values(v_id,v_cod->>'codigo',v_cod->>'descripcion',(v_item->>'cantidad')::numeric,(v_cod->>'costo')::numeric);
 end loop;
 insert into public.devoluciones_historial(devolucion_id,actor,actor_nombre,estado_nuevo) values(v_id,auth.uid(),(select coalesce(nombre_corto,usuario) from public.usuarios where auth_user_id=auth.uid() and activo is true limit 1),'Ingresada');
 return jsonb_build_object('id',v_id,'gestion',v_gestion);
end $function$;
