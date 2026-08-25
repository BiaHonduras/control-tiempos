-- BIA HONDURAS - ACTUALIZACIÓN V2.9.2
-- Nuevas actividades y flexibilidad en carga/descarga de contenedores.
-- Ejecutar después de las actualizaciones anteriores.

-- ============================================================
-- 1. INICIO DE ACTIVIDADES V8
-- ============================================================
create or replace function public.iniciar_actividad_v8(
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
  v_permite_multiples boolean;
  v_requiere_dos boolean;
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

  -- Estas actividades muestran selección múltiple.
  v_permite_multiples:=v_actividad in(
    'Preparación de Walmart',
    'Preparación de La Colonia',
    'Carga de Contenedores',
    'Descarga de Contenedores'
  );

  -- Walmart y La Colonia conservan el mínimo de 2 personas.
  -- Carga/Descarga de Contenedores ahora permiten 1 o más.
  v_requiere_dos:=v_actividad in(
    'Preparación de Walmart',
    'Preparación de La Colonia'
  );

  if v_requiere_dos and cardinality(v_ids)<2 then
    raise exception 'MINIMO_DOS_COLABORADORES';
  end if;

  if not v_permite_multiples and cardinality(v_ids)<>1 then
    raise exception 'ACTIVIDAD_REQUIERE_UN_COLABORADOR';
  end if;

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

revoke all on function public.iniciar_actividad_v8(uuid[],jsonb) from public,anon;
grant execute on function public.iniciar_actividad_v8(uuid[],jsonb) to authenticated;

-- ============================================================
-- 2. EDICIÓN ADMINISTRATIVA V2
-- Incluye las cuatro actividades nuevas y la nueva regla de contenedores.
-- ============================================================
create or replace function public.admin_actualizar_registro_historial_v2(
  p_tipo text,
  p_id uuid,
  p_cambios jsonb,
  p_motivo text
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_antes jsonb;
  v_despues jsonb;
  v_email text;
  v_timer_id uuid;
  v_facturas integer;
  v_libras numeric(12,2);
  v_actividad text;
  v_ids uuid[];
  v_nombres text[];
  v_nombre_compuesto text;
  v_principal uuid;
  v_permite_multiples boolean;
  v_requiere_dos boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.es_admin() then raise exception 'SOLO_ADMINISTRADOR'; end if;
  if p_tipo not in ('preparacion','actividad') then raise exception 'TIPO_REGISTRO_INVALIDO'; end if;
  if length(trim(coalesce(p_motivo,'')))<5 then raise exception 'MOTIVO_REQUERIDO'; end if;

  select email into v_email from auth.users where id=auth.uid();

  if p_tipo='preparacion' then
    select to_jsonb(h),h.timer_id into v_antes,v_timer_id
    from public.historial_preparaciones h where h.id=p_id for update;
    if v_antes is null then raise exception 'REGISTRO_NO_ENCONTRADO'; end if;

    v_facturas:=nullif(p_cambios->>'facturas','')::integer;
    v_libras:=nullif(p_cambios->>'libras','')::numeric;
    if v_facturas is null or v_facturas<=0 then raise exception 'FACTURAS_INVALIDAS'; end if;
    if v_libras is null or v_libras<0 then raise exception 'LIBRAS_INVALIDAS'; end if;

    update public.historial_preparaciones
    set facturas=v_facturas,libras=round(v_libras,2)
    where id=p_id;

    update public.cronometros
    set datos=jsonb_set(jsonb_set(datos,'{facturas}',to_jsonb(v_facturas),true),'{libras}',to_jsonb(round(v_libras,2)),true),
        actualizado_por=auth.uid(),actualizado_en=now(),version=version+1
    where id=v_timer_id;

    select to_jsonb(h) into v_despues from public.historial_preparaciones h where h.id=p_id;
  else
    select to_jsonb(h),h.timer_id into v_antes,v_timer_id
    from public.historial_actividades h where h.id=p_id for update;
    if v_antes is null then raise exception 'REGISTRO_NO_ENCONTRADO'; end if;

    v_actividad:=trim(coalesce(p_cambios->>'actividad',''));
    if v_actividad not in(
      'Aseo Almacén',
      'Aseo Andén | Botar Basura',
      'Aseo Parqueo',
      'Carga de Contenedores',
      'Carga de Camiones',
      'Descarga de Contenedores',
      'Descarga de Camiones',
      'Despacho Rutas Detalle',
      'Limpieza del Montacargas',
      'Orden Área Asignada',
      'Orden Bodega 033 | 095',
      'Preparación de Facturas',
      'Preparación de La Colonia',
      'Preparación de Walmart',
      'Recoger Tarimas Vacías | Fleje | B033 - B095',
      'Preparación de Rutas de Detalle',
      'Toma de Inventario'
    ) then raise exception 'ACTIVIDAD_INVALIDA'; end if;

    select array_agg(value::uuid) into v_ids
    from jsonb_array_elements_text(coalesce(p_cambios->'colaborador_ids','[]'::jsonb));
    if v_ids is null or cardinality(v_ids)=0 then raise exception 'SIN_COLABORADORES'; end if;
    if cardinality(v_ids)<>cardinality(array(select distinct unnest(v_ids))) then raise exception 'COLABORADORES_DUPLICADOS'; end if;

    v_permite_multiples:=v_actividad in(
      'Preparación de Walmart','Preparación de La Colonia','Carga de Contenedores','Descarga de Contenedores'
    );
    v_requiere_dos:=v_actividad in('Preparación de Walmart','Preparación de La Colonia');

    if v_requiere_dos and cardinality(v_ids)<2 then raise exception 'MINIMO_DOS_COLABORADORES'; end if;
    if not v_permite_multiples and cardinality(v_ids)<>1 then raise exception 'ACTIVIDAD_REQUIERE_UN_COLABORADOR'; end if;

    select array_agg(c.nombre order by u.ord)
    into v_nombres
    from unnest(v_ids) with ordinality u(id,ord)
    join public.colaboradores c on c.id=u.id
    where c.activo=true;

    if coalesce(cardinality(v_nombres),0)<>cardinality(v_ids) then raise exception 'COLABORADOR_INVALIDO_O_INACTIVO'; end if;

    v_principal:=v_ids[1];
    v_nombre_compuesto:=array_to_string(v_nombres,', ');

    update public.historial_actividades
    set colaborador_id=v_principal,
        empleado=v_nombre_compuesto,
        actividad=v_actividad,
        participantes=to_jsonb(v_nombres)
    where id=p_id;

    update public.cronometros
    set colaborador_id=v_principal,
        empleado=v_nombre_compuesto,
        datos=jsonb_set(jsonb_set(jsonb_set(datos,'{actividad}',to_jsonb(v_actividad),true),'{participantes_ids}',to_jsonb(v_ids),true),'{participantes_nombres}',to_jsonb(v_nombres),true),
        actualizado_por=auth.uid(),actualizado_en=now(),version=version+1
    where id=v_timer_id;

    select to_jsonb(h) into v_despues from public.historial_actividades h where h.id=p_id;
  end if;

  insert into public.auditoria_modificaciones(
    tipo_registro,registro_id,datos_anteriores,datos_nuevos,motivo,modificado_por,modificado_por_email
  ) values(
    p_tipo,p_id,v_antes,v_despues,trim(p_motivo),auth.uid(),v_email
  );

  return jsonb_build_object('ok',true,'tipo',p_tipo,'id',p_id,'modificado_por',v_email);
end $$;

revoke all on function public.admin_actualizar_registro_historial_v2(text,uuid,jsonb,text) from public,anon;
grant execute on function public.admin_actualizar_registro_historial_v2(text,uuid,jsonb,text) to authenticated;

notify pgrst,'reload schema';

-- Verificación final
select p.proname,pg_get_function_identity_arguments(p.oid)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in('iniciar_actividad_v8','admin_actualizar_registro_historial_v2')
order by p.proname;
