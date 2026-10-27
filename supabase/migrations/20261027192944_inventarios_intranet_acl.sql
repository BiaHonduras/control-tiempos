-- Inventarios uses the Intranet's authoritative application, role and site permissions.
alter table bia_acl_private.accounts drop constraint if exists accounts_apps_check;
alter table bia_acl_private.accounts add constraint accounts_apps_check check(apps <@ array['tiempos','contenedores','devoluciones','inventarios']);
-- Existing active Inventarios identities keep their access. Administrators always have every app.
update bia_acl_private.accounts a set apps=array_append(a.apps,'inventarios'),version=a.version+1,updated_at=now()
where not ('inventarios'=any(a.apps)) and a.active and a.deleted_at is null
  and (a.role='administrador' or exists(select 1 from public.usuarios u where u.auth_user_id=a.user_id and u.activo));
-- Extend the central directory validation without replacing later unrelated changes.
do $migration$
declare def text; old_list text:=$v$array['tiempos','contenedores','devoluciones']$v$;new_list text:=$v$array['tiempos','contenedores','devoluciones','inventarios']$v$;
begin
 select pg_get_functiondef('public.bia_directory_check(uuid,text,uuid,jsonb)'::regprocedure) into def;
 if position(old_list in def)>0 and position('cardinality(apps)<>3' in def)>0 then
  def:=replace(replace(def,old_list,new_list),'cardinality(apps)<>3','cardinality(apps)<>4');execute def;
 elsif position(new_list in def)=0 or position('cardinality(apps)<>4' in def)=0 then
  raise exception 'INTRANET_DIRECTORY_DEFINITION_CHANGED';
 end if;
end $migration$;
-- Keep the emergency bootstrap from removing the new application on recovery.
do $migration$
declare def text; old_list text:=$v$array['tiempos','contenedores','devoluciones']$v$; new_list text:=$v$array['tiempos','contenedores','devoluciones','inventarios']$v$;
begin
 select pg_get_functiondef('public.bia_bootstrap_assign(uuid,jsonb)'::regprocedure) into def;
 if position(old_list in def)>0 then execute replace(def,old_list,new_list);
 elsif position(new_list in def)=0 then raise exception 'INTRANET_BOOTSTRAP_DEFINITION_CHANGED'; end if;
end $migration$;

create or replace function public.bia_inventory_site_code(p_site text) returns text
language sql immutable set search_path='' as $$select case upper(trim(coalesce(p_site,'')))
 when 'SPS' then 'SPS' when 'SAN PEDRO SULA' then 'SPS'
 when 'CBA' then 'CBA' when 'LA CEIBA' then 'CBA'
 when 'SRC' then 'SRC' when 'SANTA ROSA DE COPÁN' then 'SRC' when 'SANTA ROSA DE COPAN' then 'SRC'
 when 'TGU' then 'TGU' when 'TEGUCIGALPA' then 'TGU'
 when 'AMT' then 'AMT' when 'AMARATECA' then 'AMT' else null end$$;
create or replace function public.bia_inventory_site_allowed(p_action text,p_site text) returns boolean
language sql stable set search_path='' as $$select public.bia_can('inventarios',p_action) and (public.bia_can('inventarios','delete') or (public.bia_inventory_site_code(p_site) is not null and public.bia_can('inventarios',p_action,public.bia_inventory_site_code(p_site))))$$;
create or replace function public.bia_inventory_bodega_allowed(p_action text,p_bodega text) returns boolean
language sql stable set search_path='' as $$select public.bia_can('inventarios',p_action) and (public.bia_can('inventarios','delete') or exists(select 1 from public.bodegas b where b.id_bodega=p_bodega and public.bia_inventory_site_allowed(p_action,b.sede)))$$;
create or replace function public.bia_inventory_log_visible(p_usuario text) returns boolean
language sql stable security definer set search_path='' as $$select public.bia_can('inventarios','read') and (public.bia_can('inventarios','delete') or exists(select 1 from public.usuarios u where lower(trim(u.usuario))=lower(trim(p_usuario)) and public.bia_inventory_site_allowed('read',u.sede)))$$;
create or replace function public.bia_inventory_log_own(p_usuario text) returns boolean
language sql stable security definer set search_path='' as $$select public.bia_can('inventarios','write') and exists(select 1 from public.usuarios u where u.auth_user_id=auth.uid() and (lower(trim(u.usuario))=lower(trim(p_usuario)) or lower(trim(u.correo))=lower(trim(p_usuario))))$$;
revoke all on function public.bia_inventory_site_code(text),public.bia_inventory_site_allowed(text,text),public.bia_inventory_bodega_allowed(text,text),public.bia_inventory_log_visible(text),public.bia_inventory_log_own(text) from public,anon;
grant execute on function public.bia_inventory_site_code(text),public.bia_inventory_site_allowed(text,text),public.bia_inventory_bodega_allowed(text,text),public.bia_inventory_log_visible(text),public.bia_inventory_log_own(text) to authenticated;

-- Previously these policies restricted everyone to a single legacy site, including administrators.
drop policy if exists inventarios_select on public.inventarios_diarios;
drop policy if exists inventarios_insert on public.inventarios_diarios;
drop policy if exists inventarios_update on public.inventarios_diarios;
drop policy if exists inventarios_intranet_select on public.inventarios_diarios;
drop policy if exists inventarios_intranet_insert on public.inventarios_diarios;
drop policy if exists inventarios_intranet_update on public.inventarios_diarios;
drop policy if exists inventarios_intranet_delete on public.inventarios_diarios;
create policy inventarios_intranet_select on public.inventarios_diarios for select to authenticated using(public.bia_inventory_site_allowed('read',sede));
create policy inventarios_intranet_insert on public.inventarios_diarios for insert to authenticated with check(public.bia_inventory_site_allowed('write',sede));
create policy inventarios_intranet_update on public.inventarios_diarios for update to authenticated using(public.bia_inventory_site_allowed('write',sede)) with check(public.bia_inventory_site_allowed('write',sede));
create policy inventarios_intranet_delete on public.inventarios_diarios for delete to authenticated using(public.bia_can('inventarios','delete'));
drop policy if exists justificaciones_select on public.inventario_justificaciones;
drop policy if exists justificaciones_insert on public.inventario_justificaciones;
drop policy if exists inventarios_intranet_select on public.inventario_justificaciones;
drop policy if exists inventarios_intranet_insert on public.inventario_justificaciones;
drop policy if exists inventarios_intranet_update on public.inventario_justificaciones;
drop policy if exists inventarios_intranet_delete on public.inventario_justificaciones;
create policy inventarios_intranet_select on public.inventario_justificaciones for select to authenticated using(public.bia_inventory_site_allowed('read',sede));
create policy inventarios_intranet_insert on public.inventario_justificaciones for insert to authenticated with check(public.bia_inventory_site_allowed('write',sede));
create policy inventarios_intranet_update on public.inventario_justificaciones for update to authenticated using(public.bia_inventory_site_allowed('write',sede)) with check(public.bia_inventory_site_allowed('write',sede));
create policy inventarios_intranet_delete on public.inventario_justificaciones for delete to authenticated using(public.bia_can('inventarios','delete'));

drop policy if exists vencimientos_select on public.vencimientos_semanales;
drop policy if exists insert_vencimientos_semanales on public.vencimientos_semanales;
drop policy if exists update_vencimientos_semanales on public.vencimientos_semanales;
drop policy if exists delete_vencimientos_semanales on public.vencimientos_semanales;
drop policy if exists inventarios_intranet_select on public.vencimientos_semanales;
drop policy if exists inventarios_intranet_insert on public.vencimientos_semanales;
drop policy if exists inventarios_intranet_update on public.vencimientos_semanales;
drop policy if exists inventarios_intranet_delete on public.vencimientos_semanales;
create policy inventarios_intranet_select on public.vencimientos_semanales for select to authenticated using(public.bia_inventory_site_allowed('read',sede));
create policy inventarios_intranet_insert on public.vencimientos_semanales for insert to authenticated with check(user_id=auth.uid() and public.bia_inventory_site_allowed('write',sede));
create policy inventarios_intranet_update on public.vencimientos_semanales for update to authenticated using(public.bia_inventory_site_allowed('write',sede) and (user_id=auth.uid() or public.bia_can('inventarios','delete'))) with check(public.bia_inventory_site_allowed('write',sede) and (user_id=auth.uid() or public.bia_can('inventarios','delete')));
create policy inventarios_intranet_delete on public.vencimientos_semanales for delete to authenticated using(public.bia_inventory_site_allowed('write',sede) and (user_id=auth.uid() or public.bia_can('inventarios','delete')));

-- Reporteria only has a warehouse ID; map it to a site before granting access.
drop policy if exists inventarios_scope_select on public.inventario_reporteria;
drop policy if exists inventarios_scope_insert on public.inventario_reporteria;
drop policy if exists inventarios_scope_update on public.inventario_reporteria;
drop policy if exists inventarios_scope_delete on public.inventario_reporteria;
create policy inventarios_scope_select on public.inventario_reporteria as restrictive for select to authenticated using(public.bia_inventory_bodega_allowed('read',"idBodega"));
create policy inventarios_scope_insert on public.inventario_reporteria as restrictive for insert to authenticated with check(public.bia_inventory_bodega_allowed('write',"idBodega"));
create policy inventarios_scope_update on public.inventario_reporteria as restrictive for update to authenticated using(public.bia_inventory_bodega_allowed('write',"idBodega")) with check(public.bia_inventory_bodega_allowed('write',"idBodega"));
create policy inventarios_scope_delete on public.inventario_reporteria as restrictive for delete to authenticated using(public.bia_can('inventarios','delete'));
drop policy if exists inventarios_scope_select on public.inventario_importaciones;
drop policy if exists inventarios_scope_insert on public.inventario_importaciones;
create policy inventarios_scope_select on public.inventario_importaciones as restrictive for select to authenticated using(public.bia_inventory_log_visible(usuario));
create policy inventarios_scope_insert on public.inventario_importaciones as restrictive for insert to authenticated with check(public.bia_inventory_log_own(usuario));

-- Preserve Contenedores and Devoluciones access to their shared SKU catalog.
drop policy if exists intranet_sku_select on public.codigos;
drop policy if exists intranet_sku_insert on public.codigos;
drop policy if exists intranet_sku_update on public.codigos;
drop policy if exists intranet_sku_delete on public.codigos;
drop policy if exists inventarios_catalog_update on public.codigos;
create policy intranet_sku_select on public.codigos as restrictive for select to authenticated using(public.bia_can('contenedores','read') or public.bia_can('devoluciones','read') or public.bia_can('inventarios','read'));
create policy intranet_sku_insert on public.codigos as restrictive for insert to authenticated with check(public.bia_can('contenedores','write') or public.bia_can('devoluciones','write') or public.bia_can('inventarios','catalogs'));
create policy intranet_sku_update on public.codigos as restrictive for update to authenticated using(public.bia_can('contenedores','write') or public.bia_can('devoluciones','write') or public.bia_can('inventarios','catalogs')) with check(public.bia_can('contenedores','write') or public.bia_can('devoluciones','write') or public.bia_can('inventarios','catalogs'));
create policy intranet_sku_delete on public.codigos as restrictive for delete to authenticated using(public.bia_can('contenedores','write') or public.bia_can('devoluciones','write') or public.bia_can('inventarios','delete'));
create policy inventarios_catalog_update on public.codigos for update to authenticated using(public.bia_can('inventarios','catalogs')) with check(public.bia_can('inventarios','catalogs'));

-- The import clears only the caller's authorized sites; administrators retain global access.
create or replace function public.rpc_limpiar_inventario_reporteria_segura(p_usuario text) returns void
language plpgsql security definer set search_path='' as $$begin
 if not public.bia_can('inventarios','write') then raise exception 'PERMISO_INSUFICIENTE';end if;
 delete from public.inventario_reporteria where codigo is not null and public.bia_inventory_bodega_allowed('write',"idBodega");
end$$;
revoke all on function public.rpc_limpiar_inventario_reporteria_segura(text) from public,anon;
grant execute on function public.rpc_limpiar_inventario_reporteria_segura(text) to authenticated;

-- All legacy security-definer RPCs enforce the canonical identity instead of a client-supplied name.
do $migration$
declare r record; def text; guard text; marker text:='-- INVENTARIOS_CANONICAL_GUARD_V1';
begin
 for r in select p.oid,p.proname,pg_get_function_identity_arguments(p.oid) as args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('rpc_eliminar_articulo_seguro','rpc_eliminar_inventarios_completo_seguro','rpc_eliminar_inventario_completo_seguro','rpc_limpiar_vencimientos_seguro','rpc_eliminar_base_codigos_segura','rpc_guardar_justificacion_articulo_segura','rpc_guardar_justificaciones_masivas_segura') loop
  def:=pg_get_functiondef(r.oid);
  if position(marker in def)=0 then
   if r.proname='rpc_guardar_justificacion_articulo_segura' then
    guard:=$g$ if not exists(select 1 from public.inventarios_diarios i where i.id::text=p_id and public.bia_inventory_site_allowed('write',i.sede)) then raise exception 'PERMISO_INSUFICIENTE';end if; $g$;
   elsif r.proname='rpc_guardar_justificaciones_masivas_segura' then
    guard:=$g$ if not public.bia_can('inventarios','write') then raise exception 'PERMISO_INSUFICIENTE';end if; if jsonb_typeof(p_registros)='array' and exists(select 1 from jsonb_array_elements(p_registros) j where not public.bia_inventory_site_allowed('write',j->>'sede')) then raise exception 'SEDE_NO_AUTORIZADA';end if; $g$;
   else
    guard:=$g$ if not public.bia_can('inventarios','delete') then raise exception 'SOLO_ADMINISTRADOR';end if; $g$;
   end if;
   if def !~* '\mbegin\M' then raise exception 'FUNCION_INVENTARIO_SIN_BEGIN: %',r.proname;end if;
   def:=regexp_replace(def,'\mbegin\M','BEGIN'||chr(10)||marker||chr(10)||guard,'i');
   execute def;
  end if;
  execute format('revoke all on function public.%I(%s) from public,anon',r.proname,r.args);
  execute format('grant execute on function public.%I(%s) to authenticated',r.proname,r.args);
 end loop;
end $migration$;
-- Older unused global deletion RPCs were callable without authentication.
revoke all on function public.eliminar_inventarios_completo(),public.limpiar_inventario_reporteria() from public,anon,authenticated;
-- Inventory configuration and stored backups are not anonymous resources.
drop policy if exists inventarios_config_read on public.configuracion;
drop policy if exists inventarios_config_insert on public.configuracion;
drop policy if exists inventarios_config_update on public.configuracion;
create policy inventarios_config_read on public.configuracion as restrictive for select to authenticated using(public.bia_can('inventarios','read'));
create policy inventarios_config_insert on public.configuracion as restrictive for insert to authenticated with check(public.bia_can('inventarios','catalogs'));
create policy inventarios_config_update on public.configuracion as restrictive for update to authenticated using(public.bia_can('inventarios','catalogs')) with check(public.bia_can('inventarios','catalogs'));
drop policy if exists inventarios_backup_history_read on public.historial_respaldos;
drop policy if exists inventarios_backup_history_insert on public.historial_respaldos;
create policy inventarios_backup_history_read on public.historial_respaldos for select to authenticated using(public.bia_can('inventarios','delete'));
create policy inventarios_backup_history_insert on public.historial_respaldos for insert to authenticated with check(public.bia_can('inventarios','delete'));
drop policy if exists "eliminar respaldos del bucket" on storage.objects;
drop policy if exists "listar respaldos solo carpeta eliminaciones" on storage.objects;
drop policy if exists "subir respaldos solo carpeta eliminaciones" on storage.objects;
drop policy if exists inventarios_backup_storage_read on storage.objects;
drop policy if exists inventarios_backup_storage_insert on storage.objects;
drop policy if exists inventarios_backup_storage_delete on storage.objects;
create policy inventarios_backup_storage_read on storage.objects for select to authenticated using(bucket_id='respaldos-sistema' and (storage.foldername(name))[1]='eliminaciones' and public.bia_can('inventarios','delete'));
create policy inventarios_backup_storage_insert on storage.objects for insert to authenticated with check(bucket_id='respaldos-sistema' and (storage.foldername(name))[1]='eliminaciones' and public.bia_can('inventarios','delete'));
create policy inventarios_backup_storage_delete on storage.objects for delete to authenticated using(bucket_id='respaldos-sistema' and public.bia_can('inventarios','delete'));
-- The four inventory templates are private and only available to authorized inventory users.
drop policy if exists inventarios_templates_read on storage.objects;
create policy inventarios_templates_read on storage.objects for select to authenticated using(
 bucket_id='Assets' and name in ('Convertidor IR.xlsm','Formato Inventario.csv','Convertidor BDD.xlsm','Formato BDD.csv')
 and public.bia_can('inventarios','read')
);
notify pgrst,'reload schema';
