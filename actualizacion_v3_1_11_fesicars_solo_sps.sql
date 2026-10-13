-- Fesi Cars tiene únicamente el acceso asignado a SPS; sin privilegios maestros.
create or replace function public.usuario_es_maestro() returns boolean
language sql stable security definer set search_path=public
as $$ select public.usuario_password_actualizada() and exists(select 1 from auth.users where id=auth.uid() and lower(coalesce(email,''))='javierh@biabrands.co'); $$;
delete from public.usuarios_sedes where user_id in(select id from auth.users where lower(email)='fesicars@gmail.com') and sede<>'SPS';
notify pgrst,'reload schema';
