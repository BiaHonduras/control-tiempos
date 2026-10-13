-- BIA HONDURAS · v3.0.7
-- Permisos mínimos para editar/asignar accesos existentes desde Administración.
-- No crea usuarios Auth; las cuentas nuevas se crean mediante Edge Function admin-users.

grant usage on schema public to authenticated, service_role;

do $$
begin
  if to_regprocedure('public.master_asignar_usuario_existente(text,text,text,text,boolean)') is not null then
    execute 'grant execute on function public.master_asignar_usuario_existente(text,text,text,text,boolean) to authenticated, service_role';
  end if;
  if to_regprocedure('public.master_cambiar_estado_acceso(uuid,text,boolean)') is not null then
    execute 'grant execute on function public.master_cambiar_estado_acceso(uuid,text,boolean) to authenticated, service_role';
  end if;
  if to_regprocedure('public.listar_usuarios_sede_v1(text)') is not null then
    execute 'grant execute on function public.listar_usuarios_sede_v1(text) to authenticated, service_role';
  end if;
end $$;

notify pgrst,'reload schema';

select
  'master_asignar_usuario_existente' as funcion,
  has_function_privilege('authenticated','public.master_asignar_usuario_existente(text,text,text,text,boolean)','EXECUTE') as puede_ejecutar;
