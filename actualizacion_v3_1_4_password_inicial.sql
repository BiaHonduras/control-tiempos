-- Exigir el cambio de contraseña inicial usando metadatos administrados por Auth.
create or replace function public.usuario_password_actualizada() returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from auth.users where id=auth.uid() and coalesce(raw_app_meta_data->>'must_change_password','false') <> 'true'); $$;
revoke all on function public.usuario_password_actualizada() from public, anon;
grant execute on function public.usuario_password_actualizada() to authenticated, service_role;
create or replace function public.usuario_es_maestro() returns boolean
language sql stable security definer set search_path=public
as $$ select public.usuario_password_actualizada() and exists(select 1 from auth.users where id=auth.uid() and lower(coalesce(email,''))='javierh@biabrands.co'); $$;
create or replace function public.usuario_es_admin_sede(p_sede text) returns boolean
language sql stable security definer set search_path=public
as $$ select public.usuario_password_actualizada() and (public.usuario_es_maestro() or exists(select 1 from public.usuarios_sedes where user_id=auth.uid() and sede=upper(p_sede) and activo and rol='admin')); $$;
create or replace function public.usuario_puede_sede(p_sede text) returns boolean
language sql stable security definer set search_path=public
as $$ select public.usuario_password_actualizada() and (public.usuario_es_maestro() or exists(select 1 from public.usuarios_sedes where user_id=auth.uid() and sede=upper(p_sede) and activo)); $$;
notify pgrst,'reload schema';
