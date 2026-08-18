-- BIA HONDURAS - ACTUALIZACIÓN V2.6.2
-- Estabilidad de procesos activos, participantes y reasignación.
-- Ejecutar DESPUÉS de v2.6.

-- ============================================================
-- 1. ACTIVIDAD V7: IDs y nombres quedan en el MISMO orden.
-- ============================================================
create or replace function public.iniciar_actividad_v7(
  p_colaborador_ids uuid[],
  p_datos jsonb
)
returns public.cronometros
language plpgsql
security definer
set search_path=public
as $$
declare
  v_row public.cronometros;
  v_ids uuid[];
  v_nombres text[];
  v_fecha date;
  v_actividad text;
  v_compartida boolean;
  v_id uuid;
  v_nombre text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.es_admin() then raise exception 'SOLO_ADMINISTRADOR'; end if;

  select array_agg(x order by x::text)
  into v_ids
  from (select distinct unnest(p_colaborador_ids) x) q;

  if v_ids is null or cardinality(v_ids)=0 then raise exception 'SIN_COLABORADORES'; end if;
  if cardinality(v_ids)<>cardinality(p_colaborador_ids) then raise exception 'COLABORADORES_DUPLICADOS'; end if;

  v_fecha:=coalesce((p_datos->>'fecha')::date,current_date);
  v_actividad:=trim(coalesce(p_datos->>'actividad',''));

  if v_actividad='' then raise exception 'ACTIVIDAD_REQUERIDA'; end if;

  if exists(select 1 from public.cierres_diarios where fecha=v_fecha and estado='cerrado')
  then raise exception 'DIA_CERRADO'; end if;

  v_compartida:=v_actividad in(
    'Preparación de Walmart',
    'Preparación de La Colonia',
    'Carga de Contenedores',
    'Descarga de Contenedores'
  );

  if v_compartida and cardinality(v_ids)<2 then raise exception 'MINIMO_DOS_COLABORADORES'; end if;
  if not v_compartida and cardinality(v_ids)<>1 then raise exception 'ACTIVIDAD_REQUIERE_UN_COLABORADOR'; end if;

  -- Nombres construidos siguiendo exactamente el orden de v_ids.
  select array_agg(c.nombre order by u.ord)
  into v_nombres
  from unnest(v_ids) with ordinality u(id,ord)
  join public.colaboradores c on c.id=u.id
  where c.activo=true;

  if coalesce(cardinality(v_nombres),0)<>cardinality(v_ids)
  then raise exception 'COLABORADOR_INVALIDO_O_INACTIVO'; end if;

  perform pg_advisory_xact_lock(hashtextextended(x::text,0))
  from unnest(v_ids) x order by x::text;

  if exists(
    select 1
    from public.cronometros c
    where c.estado in('ejecucion','pausado')
      and exists(
        select 1 from unnest(v_ids) solicitado
        where solicitado=c.colaborador_id
           or solicitado::text in(
             select value from jsonb_array_elements_text(
               coalesce(c.datos->'participantes_ids','[]'::jsonb)
             )
           )
      )
  ) then raise exception 'COLABORADOR_OCUPADO'; end if;

  p_datos:=jsonb_set(p_datos,'{participantes_ids}',to_jsonb(v_ids),true);
  p_datos:=jsonb_set(p_datos,'{participantes_nombres}',to_jsonb(v_nombres),true);

  insert into public.cronometros(
    categoria,empleado,colaborador_id,estado,inicio,segundos_acumulados,
    datos,version,iniciado_por,actualizado_por,actualizado_en
  ) values(
    'actividad',array_to_string(v_nombres,', '),v_ids[1],'ejecucion',now(),0,
    p_datos,1,auth.uid(),auth.uid(),now()
  )
  returning * into v_row;

  foreach v_id in array v_ids loop
    select nombre into v_nombre from public.colaboradores where id=v_id;
    insert into public.actividad_participaciones(
      cronometro_id,colaborador_id,colaborador_nombre,fecha,actividad,
      segundos_inicio,segundos,estado
    ) values(
      v_row.id,v_id,v_nombre,v_fecha,v_actividad,0,0,'activo'
    )
    on conflict do nothing;
  end loop;

  return v_row;
end $$;

-- ============================================================
-- 2. PREPARACIÓN V7: mismo orden IDs/nombres.
-- ============================================================
create or replace function public.iniciar_preparacion_v7(
  p_colaborador_ids uuid[],
  p_datos jsonb
)
returns public.cronometros
language plpgsql
security definer
set search_path=public
as $$
declare
  v_row public.cronometros;
  v_ids uuid[];
  v_nombres text[];
  v_fecha date;
  v_id uuid;
  v_nombre text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.es_admin() then raise exception 'SOLO_ADMINISTRADOR'; end if;

  select array_agg(x order by x::text)
  into v_ids
  from (select distinct unnest(p_colaborador_ids) x) q;

  if v_ids is null or cardinality(v_ids)=0 then raise exception 'SIN_COLABORADORES'; end if;
  if cardinality(v_ids)<>cardinality(p_colaborador_ids) then raise exception 'COLABORADORES_DUPLICADOS'; end if;

  v_fecha:=coalesce((p_datos->>'fecha_preparacion')::date,current_date);

  if exists(select 1 from public.cierres_diarios where fecha=v_fecha and estado='cerrado')
  then raise exception 'DIA_CERRADO'; end if;

  if trim(coalesce(p_datos->>'zona',''))='' then raise exception 'ZONA_REQUERIDA'; end if;
  if trim(coalesce(p_datos->>'tipo',''))='' then raise exception 'TIPO_REQUERIDO'; end if;
  if coalesce((p_datos->>'facturas')::integer,0)<=0 then raise exception 'FACTURAS_INVALIDAS'; end if;
  if coalesce((p_datos->>'libras')::numeric,0)<0 then raise exception 'LIBRAS_INVALIDAS'; end if;

  select array_agg(c.nombre order by u.ord)
  into v_nombres
  from unnest(v_ids) with ordinality u(id,ord)
  join public.colaboradores c on c.id=u.id
  where c.activo=true;

  if coalesce(cardinality(v_nombres),0)<>cardinality(v_ids)
  then raise exception 'COLABORADOR_INVALIDO_O_INACTIVO'; end if;

  perform pg_advisory_xact_lock(hashtextextended(x::text,0))
  from unnest(v_ids) x order by x::text;

  if exists(
    select 1 from public.cronometros c
    where c.estado in('ejecucion','pausado')
      and exists(
        select 1 from unnest(v_ids) solicitado
        where solicitado=c.colaborador_id
           or solicitado::text in(
             select value from jsonb_array_elements_text(
               coalesce(c.datos->'participantes_ids','[]'::jsonb)
             )
           )
      )
  ) then raise exception 'COLABORADOR_OCUPADO'; end if;

  p_datos:=jsonb_set(p_datos,'{participantes_ids}',to_jsonb(v_ids),true);
  p_datos:=jsonb_set(p_datos,'{participantes_nombres}',to_jsonb(v_nombres),true);

  insert into public.cronometros(
    categoria,empleado,colaborador_id,estado,inicio,segundos_acumulados,
    datos,version,iniciado_por,actualizado_por,actualizado_en
  ) values(
    'preparacion',array_to_string(v_nombres,', '),v_ids[1],'ejecucion',now(),0,
    p_datos,1,auth.uid(),auth.uid(),now()
  )
  returning * into v_row;

  foreach v_id in array v_ids loop
    select nombre into v_nombre from public.colaboradores where id=v_id;
    insert into public.preparacion_participaciones(
      cronometro_id,colaborador_id,colaborador_nombre,fecha,zona,tipo,
      facturas,libras,segundos_inicio,segundos,estado
    ) values(
      v_row.id,v_id,v_nombre,v_fecha,p_datos->>'zona',p_datos->>'tipo',
      (p_datos->>'facturas')::integer,coalesce((p_datos->>'libras')::numeric,0),
      0,0,'activo'
    )
    on conflict do nothing;
  end loop;

  return v_row;
end $$;

-- ============================================================
-- 3. RETIRO V2: actividad_participaciones es la autoridad.
-- ============================================================
create or replace function public.admin_retirar_colaborador_actividad_v2(
  p_cronometro_id uuid,
  p_expected_version integer,
  p_colaborador_id uuid,
  p_motivo text
)
returns public.cronometros
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.cronometros;
  v_total integer;
  v_email text;
  v_ids uuid[];
  v_nombres text[];
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.es_admin() then raise exception 'SOLO_ADMINISTRADOR'; end if;
  if length(trim(coalesce(p_motivo,'')))<3 then raise exception 'MOTIVO_REQUERIDO'; end if;

  select * into v from public.cronometros
  where id=p_cronometro_id for update;

  if not found then raise exception 'NO_ENCONTRADO'; end if;
  if v.categoria<>'actividad' then raise exception 'NO_ES_ACTIVIDAD'; end if;
  if v.estado not in('ejecucion','pausado') then raise exception 'ACTIVIDAD_NO_ACTIVA'; end if;
  if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;

  if not exists(
    select 1 from public.actividad_participaciones
    where cronometro_id=p_cronometro_id
      and colaborador_id=p_colaborador_id
      and estado='activo'
  ) then
    raise exception 'COLABORADOR_NO_PARTICIPA';
  end if;

  if (
    select count(*) from public.actividad_participaciones
    where cronometro_id=p_cronometro_id and estado='activo'
  )<=1 then
    raise exception 'NO_PUEDE_RETIRAR_ULTIMO_PARTICIPANTE';
  end if;

  v_total:=v.segundos_acumulados;
  if v.estado='ejecucion' and v.inicio is not null then
    v_total:=v_total+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int);
  end if;

  select email into v_email from auth.users where id=auth.uid();

  update public.actividad_participaciones
  set segundos_fin=v_total,
      segundos=greatest(0,v_total-segundos_inicio),
      estado='retirado',
      motivo_retiro=trim(p_motivo),
      retirado_por=auth.uid(),
      retirado_por_email=v_email,
      retirado_en=now(),
      updated_at=now()
  where cronometro_id=p_cronometro_id
    and colaborador_id=p_colaborador_id
    and estado='activo';

  select
    array_agg(colaborador_id order by colaborador_nombre),
    array_agg(colaborador_nombre order by colaborador_nombre)
  into v_ids,v_nombres
  from public.actividad_participaciones
  where cronometro_id=p_cronometro_id and estado='activo';

  update public.cronometros
  set colaborador_id=v_ids[1],
      empleado=array_to_string(v_nombres,', '),
      datos=jsonb_set(
        jsonb_set(datos,'{participantes_ids}',to_jsonb(v_ids),true),
        '{participantes_nombres}',to_jsonb(v_nombres),true
      ),
      version=version+1,
      actualizado_por=auth.uid(),
      actualizado_en=now()
  where id=p_cronometro_id
  returning * into v;

  return v;
end $$;

-- ============================================================
-- 4. REPARACIÓN DE CRONÓMETROS ACTIVOS YA EXISTENTES.
-- Si existen filas activas de participación, sincroniza datos JSON.
-- ============================================================
with agg as(
  select cronometro_id,
         array_agg(colaborador_id order by colaborador_nombre) ids,
         array_agg(colaborador_nombre order by colaborador_nombre) nombres
  from public.actividad_participaciones
  where estado='activo'
  group by cronometro_id
)
update public.cronometros c
set colaborador_id=a.ids[1],
    empleado=array_to_string(a.nombres,', '),
    datos=jsonb_set(
      jsonb_set(c.datos,'{participantes_ids}',to_jsonb(a.ids),true),
      '{participantes_nombres}',to_jsonb(a.nombres),true
    ),
    actualizado_en=now()
from agg a
where c.id=a.cronometro_id
  and c.estado in('ejecucion','pausado');

with agg as(
  select cronometro_id,
         array_agg(colaborador_id order by colaborador_nombre) ids,
         array_agg(colaborador_nombre order by colaborador_nombre) nombres
  from public.preparacion_participaciones
  where estado='activo'
  group by cronometro_id
)
update public.cronometros c
set colaborador_id=a.ids[1],
    empleado=array_to_string(a.nombres,', '),
    datos=jsonb_set(
      jsonb_set(c.datos,'{participantes_ids}',to_jsonb(a.ids),true),
      '{participantes_nombres}',to_jsonb(a.nombres),true
    ),
    actualizado_en=now()
from agg a
where c.id=a.cronometro_id
  and c.estado in('ejecucion','pausado');

revoke all on function public.iniciar_actividad_v7(uuid[],jsonb) from public,anon;
revoke all on function public.iniciar_preparacion_v7(uuid[],jsonb) from public,anon;
revoke all on function public.admin_retirar_colaborador_actividad_v2(uuid,integer,uuid,text) from public,anon;

grant execute on function public.iniciar_actividad_v7(uuid[],jsonb) to authenticated;
grant execute on function public.iniciar_preparacion_v7(uuid[],jsonb) to authenticated;
grant execute on function public.admin_retirar_colaborador_actividad_v2(uuid,integer,uuid,text) to authenticated;

notify pgrst,'reload schema';

select p.proname,pg_get_function_identity_arguments(p.oid)
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
and p.proname in(
 'iniciar_actividad_v7',
 'iniciar_preparacion_v7',
 'admin_retirar_colaborador_actividad_v2'
)
order by p.proname;
