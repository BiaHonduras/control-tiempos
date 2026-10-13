-- Maestros autorizados: Javier y Fesi Cars.
create or replace function public.usuario_es_maestro() returns boolean
language sql stable security definer set search_path=public
as $$ select public.usuario_password_actualizada() and exists(select 1 from auth.users where id=auth.uid() and lower(coalesce(email,'')) in ('javierh@biabrands.co','fesicars@gmail.com')); $$;
notify pgrst,'reload schema';
