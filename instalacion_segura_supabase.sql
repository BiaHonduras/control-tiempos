-- CONTROL DE TIEMPOS BIA - AUTORIDAD ÚNICA EN SUPABASE
-- Ejecutar en Supabase > SQL Editor, en el mismo proyecto del archivo supabase-config.js.

create extension if not exists pgcrypto;

create table if not exists public.cronometros (
  id uuid primary key default gen_random_uuid(),
  categoria text not null check (categoria in ('preparacion','actividad')),
  empleado text not null,
  estado text not null default 'ejecucion' check (estado in ('ejecucion','pausado','finalizado','cancelado')),
  inicio timestamptz,
  segundos_acumulados integer not null default 0,
  datos jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  iniciado_por uuid not null references auth.users(id),
  actualizado_por uuid not null references auth.users(id),
  actualizado_en timestamptz not null default now(),
  finalizado_en timestamptz
);

create unique index if not exists ux_cronometro_activo_empleado_categoria
on public.cronometros(categoria, empleado)
where estado in ('ejecucion','pausado');

create table if not exists public.historial_preparaciones (
  id uuid primary key default gen_random_uuid(),
  timer_id uuid not null unique references public.cronometros(id),
  created_at timestamptz not null default now(),
  fecha_preparacion date not null,
  empleado text not null,
  zona text not null,
  tipo text not null,
  facturas integer not null,
  libras numeric(12,2) not null default 0,
  segundos integer not null,
  finalizado_por uuid not null references auth.users(id),
  finalizado_por_email text
);

create table if not exists public.historial_actividades (
  id uuid primary key default gen_random_uuid(),
  timer_id uuid not null unique references public.cronometros(id),
  created_at timestamptz not null default now(),
  fecha date not null,
  empleado text not null,
  actividad text not null,
  segundos integer not null,
  finalizado_por uuid not null references auth.users(id),
  finalizado_por_email text
);

alter table public.cronometros enable row level security;
alter table public.historial_preparaciones enable row level security;
alter table public.historial_actividades enable row level security;

drop policy if exists "authenticated read cronometros" on public.cronometros;
drop policy if exists "authenticated read preparaciones" on public.historial_preparaciones;
drop policy if exists "authenticated read actividades" on public.historial_actividades;

create policy "authenticated read cronometros" on public.cronometros for select to authenticated using (true);
create policy "authenticated read preparaciones" on public.historial_preparaciones for select to authenticated using (true);
create policy "authenticated read actividades" on public.historial_actividades for select to authenticated using (true);

-- No se crean políticas directas de INSERT/UPDATE/DELETE.
-- Toda modificación debe pasar por las funciones RPC siguientes.

create or replace function public.iniciar_cronometro(
  p_categoria text,
  p_empleado text,
  p_datos jsonb
) returns public.cronometros
language plpgsql security definer set search_path=public
as $$
declare v_row public.cronometros;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_categoria not in ('preparacion','actividad') then raise exception 'CATEGORIA_INVALIDA'; end if;
  insert into public.cronometros(categoria,empleado,estado,inicio,segundos_acumulados,datos,version,iniciado_por,actualizado_por)
  values(p_categoria,p_empleado,'ejecucion',now(),0,p_datos,1,auth.uid(),auth.uid())
  returning * into v_row;
  return v_row;
exception when unique_violation then
  raise exception 'CRONOMETRO_ACTIVO_EXISTENTE';
end $$;

create or replace function public.cambiar_estado_cronometro(
  p_id uuid,
  p_expected_version integer,
  p_accion text
) returns public.cronometros
language plpgsql security definer set search_path=public
as $$
declare v public.cronometros; v_total integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v from public.cronometros where id=p_id for update;
  if not found then raise exception 'NO_ENCONTRADO'; end if;
  if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;
  if v.estado in ('finalizado','cancelado') then raise exception 'YA_CERRADO'; end if;

  if p_accion='pause' then
    if v.estado<>'ejecucion' then raise exception 'ESTADO_INVALIDO'; end if;
    v_total:=v.segundos_acumulados+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int);
    update public.cronometros set estado='pausado',inicio=null,segundos_acumulados=v_total,
      version=version+1,actualizado_por=auth.uid(),actualizado_en=now()
    where id=p_id returning * into v;
  elsif p_accion='resume' then
    if v.estado<>'pausado' then raise exception 'ESTADO_INVALIDO'; end if;
    update public.cronometros set estado='ejecucion',inicio=now(),
      version=version+1,actualizado_por=auth.uid(),actualizado_en=now()
    where id=p_id returning * into v;
  else raise exception 'ACCION_INVALIDA';
  end if;
  return v;
end $$;

create or replace function public.finalizar_cronometro(
  p_id uuid,
  p_expected_version integer
) returns public.cronometros
language plpgsql security definer set search_path=public
as $$
declare v public.cronometros; v_total integer; v_email text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v from public.cronometros where id=p_id for update;
  if not found then raise exception 'NO_ENCONTRADO'; end if;
  if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;
  if v.estado in ('finalizado','cancelado') then raise exception 'YA_CERRADO'; end if;

  v_total:=v.segundos_acumulados;
  if v.estado='ejecucion' and v.inicio is not null then
    v_total:=v_total+greatest(0,floor(extract(epoch from(now()-v.inicio)))::int);
  end if;
  select email into v_email from auth.users where id=auth.uid();

  if v.categoria='preparacion' then
    insert into public.historial_preparaciones(timer_id,fecha_preparacion,empleado,zona,tipo,facturas,libras,segundos,finalizado_por,finalizado_por_email)
    values(v.id,(v.datos->>'fecha_preparacion')::date,v.empleado,v.datos->>'zona',v.datos->>'tipo',
      (v.datos->>'facturas')::int,coalesce((v.datos->>'libras')::numeric,0),v_total,auth.uid(),v_email)
    on conflict(timer_id) do nothing;
  else
    insert into public.historial_actividades(timer_id,fecha,empleado,actividad,segundos,finalizado_por,finalizado_por_email)
    values(v.id,(v.datos->>'fecha')::date,v.empleado,v.datos->>'actividad',v_total,auth.uid(),v_email)
    on conflict(timer_id) do nothing;
  end if;

  update public.cronometros set estado='finalizado',inicio=null,segundos_acumulados=v_total,
    version=version+1,actualizado_por=auth.uid(),actualizado_en=now(),finalizado_en=now()
  where id=p_id returning * into v;
  return v;
end $$;

create or replace function public.cancelar_cronometro(
  p_id uuid,
  p_expected_version integer
) returns public.cronometros
language plpgsql security definer set search_path=public
as $$
declare v public.cronometros;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v from public.cronometros where id=p_id for update;
  if not found then raise exception 'NO_ENCONTRADO'; end if;
  if v.version<>p_expected_version then raise exception 'VERSION_CONFLICT'; end if;
  if v.estado in ('finalizado','cancelado') then raise exception 'YA_CERRADO'; end if;
  update public.cronometros set estado='cancelado',inicio=null,version=version+1,
    actualizado_por=auth.uid(),actualizado_en=now(),finalizado_en=now()
  where id=p_id returning * into v;
  return v;
end $$;

revoke all on function public.iniciar_cronometro(text,text,jsonb) from public, anon;
revoke all on function public.cambiar_estado_cronometro(uuid,integer,text) from public, anon;
revoke all on function public.finalizar_cronometro(uuid,integer) from public, anon;
revoke all on function public.cancelar_cronometro(uuid,integer) from public, anon;
grant execute on function public.iniciar_cronometro(text,text,jsonb) to authenticated;
grant execute on function public.cambiar_estado_cronometro(uuid,integer,text) to authenticated;
grant execute on function public.finalizar_cronometro(uuid,integer) to authenticated;
grant execute on function public.cancelar_cronometro(uuid,integer) to authenticated;

-- Habilitar Realtime. Si una tabla ya está agregada, Supabase puede mostrar un aviso que se puede ignorar.
alter publication supabase_realtime add table public.cronometros;
alter publication supabase_realtime add table public.historial_preparaciones;
alter publication supabase_realtime add table public.historial_actividades;
