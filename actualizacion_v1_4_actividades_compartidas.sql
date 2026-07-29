-- ACTUALIZACIÓN V1.4: ACTIVIDADES COMPARTIDAS
-- Ejecutar después de instalacion_segura_supabase.sql y actualizacion_v1_2_colaboradores_admin.sql.

alter table public.historial_actividades add column if not exists participantes jsonb not null default '[]'::jsonb;

create or replace function public.iniciar_actividad_compartida(
  p_colaborador_ids uuid[],
  p_datos jsonb
) returns public.cronometros
language plpgsql security definer set search_path=public
as $$
declare
  v_row public.cronometros;
  v_id uuid;
  v_nombres text[];
  v_nombre_principal text;
  v_actividad text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_colaborador_ids is null or cardinality(p_colaborador_ids)=0 then raise exception 'SIN_COLABORADORES'; end if;
  if cardinality(p_colaborador_ids) <> cardinality(array(select distinct unnest(p_colaborador_ids))) then raise exception 'COLABORADORES_DUPLICADOS'; end if;

  v_actividad := p_datos->>'actividad';
  if v_actividad in ('Preparación de Walmart','Preparación de La Colonia','Carga de Contenedores','Descarga de Contenedores') then
    if cardinality(p_colaborador_ids)<2 then raise exception 'MINIMO_DOS_COLABORADORES'; end if;
  elsif cardinality(p_colaborador_ids)<>1 then
    raise exception 'ACTIVIDAD_NO_COMPARTIDA';
  end if;

  select array_agg(nombre order by nombre) into v_nombres
  from public.colaboradores
  where id=any(p_colaborador_ids) and activo=true;
  if coalesce(cardinality(v_nombres),0)<>cardinality(p_colaborador_ids) then raise exception 'COLABORADOR_INVALIDO_O_INACTIVO'; end if;

  -- Bloqueo transaccional estable para evitar dos inicios simultáneos.
  perform pg_advisory_xact_lock(hashtextextended(x::text,0)) from unnest(p_colaborador_ids) x order by x::text;

  if exists(
    select 1 from public.cronometros c
    where c.estado in ('ejecucion','pausado')
      and c.categoria='actividad'
      and (
        c.colaborador_id=any(p_colaborador_ids)
        or exists(
          select 1 from jsonb_array_elements_text(coalesce(c.datos->'participantes_ids','[]'::jsonb)) j
          where j.value::uuid=any(p_colaborador_ids)
        )
      )
  ) then raise exception 'COLABORADOR_OCUPADO'; end if;

  select nombre into v_nombre_principal from public.colaboradores where id=p_colaborador_ids[1];
  p_datos := jsonb_set(p_datos,'{participantes_ids}',to_jsonb(p_colaborador_ids),true);
  p_datos := jsonb_set(p_datos,'{participantes_nombres}',to_jsonb(v_nombres),true);

  insert into public.cronometros(categoria,empleado,colaborador_id,estado,inicio,segundos_acumulados,datos,version,iniciado_por,actualizado_por)
  values('actividad',array_to_string(v_nombres,', '),p_colaborador_ids[1],'ejecucion',now(),0,p_datos,1,auth.uid(),auth.uid())
  returning * into v_row;
  return v_row;
end $$;

revoke all on function public.iniciar_actividad_compartida(uuid[],jsonb) from public,anon;
grant execute on function public.iniciar_actividad_compartida(uuid[],jsonb) to authenticated;

create or replace function public.finalizar_cronometro(p_id uuid,p_expected_version integer) returns public.cronometros language plpgsql security definer set search_path=public as $$
declare v public.cronometros; v_total integer; v_email text; v_participantes jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into v from public.cronometros where id=p_id for update;
 if not found then raise exception 'NO_ENCONTRADO'; end if;
 if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;
 if v.estado in('finalizado','cancelado') then raise exception 'YA_CERRADO'; end if;
 v_total:=v.segundos_acumulados;
 if v.estado='ejecucion' and v.inicio is not null then v_total:=v_total+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int); end if;
 select email into v_email from auth.users where id=auth.uid();
 if v.categoria='preparacion' then
  insert into public.historial_preparaciones(timer_id,colaborador_id,fecha_preparacion,empleado,zona,tipo,facturas,libras,segundos,finalizado_por,finalizado_por_email)
  values(v.id,v.colaborador_id,(v.datos->>'fecha_preparacion')::date,v.empleado,v.datos->>'zona',v.datos->>'tipo',(v.datos->>'facturas')::int,coalesce((v.datos->>'libras')::numeric,0),v_total,auth.uid(),v_email) on conflict(timer_id) do nothing;
 else
  v_participantes:=coalesce(v.datos->'participantes_nombres',jsonb_build_array(v.empleado));
  insert into public.historial_actividades(timer_id,colaborador_id,fecha,empleado,actividad,segundos,finalizado_por,finalizado_por_email,participantes)
  values(v.id,v.colaborador_id,(v.datos->>'fecha')::date,array_to_string(array(select jsonb_array_elements_text(v_participantes)),', '),v.datos->>'actividad',v_total,auth.uid(),v_email,v_participantes) on conflict(timer_id) do nothing;
 end if;
 update public.cronometros set estado='finalizado',inicio=null,segundos_acumulados=v_total,version=version+1,actualizado_por=auth.uid(),actualizado_en=now(),finalizado_en=now() where id=p_id returning * into v;
 return v;
end $$;

-- Impide editar/desactivar a cualquier participante de una actividad activa.
create or replace function public.colaborador_en_cronometro_activo(p_id uuid) returns boolean language sql stable security definer set search_path=public as $$
select exists(
 select 1 from public.cronometros c where c.estado in('ejecucion','pausado') and (
 c.colaborador_id=p_id or exists(select 1 from jsonb_array_elements_text(coalesce(c.datos->'participantes_ids','[]'::jsonb)) j where j.value::uuid=p_id)
 )
)$$;

create or replace function public.admin_guardar_colaborador(p_id uuid,p_nombre text,p_codigo text) returns public.colaboradores language plpgsql security definer set search_path=public as $$
declare v public.colaboradores;
begin
 if not public.es_admin() then raise exception 'SOLO_ADMINISTRADOR'; end if;
 if length(trim(p_nombre))<3 then raise exception 'NOMBRE_INVALIDO'; end if;
 if p_id is null then insert into public.colaboradores(nombre,codigo) values(trim(p_nombre),nullif(trim(p_codigo),'')) returning * into v;
 else
   if public.colaborador_en_cronometro_activo(p_id) then raise exception 'NO_SE_PUEDE_EDITAR_CON_CRONOMETRO_ACTIVO'; end if;
   update public.colaboradores set nombre=trim(p_nombre),codigo=nullif(trim(p_codigo),''),updated_at=now() where id=p_id returning * into v;
 end if;
 return v;
end $$;

create or replace function public.admin_cambiar_estado_colaborador(p_id uuid,p_activo boolean) returns public.colaboradores language plpgsql security definer set search_path=public as $$
declare v public.colaboradores;
begin
 if not public.es_admin() then raise exception 'SOLO_ADMINISTRADOR'; end if;
 if not p_activo and public.colaborador_en_cronometro_activo(p_id) then raise exception 'NO_SE_PUEDE_DESACTIVAR_CON_CRONOMETRO_ACTIVO'; end if;
 update public.colaboradores set activo=p_activo,updated_at=now() where id=p_id returning * into v;
 return v;
end $$;
