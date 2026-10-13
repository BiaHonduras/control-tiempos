CREATE OR REPLACE FUNCTION public.master_asignar_usuario_existente(p_email text, p_nombre text, p_sede text, p_rol text, p_puede_cierre boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare uid uuid; em text:=lower(trim(p_email)); s text:=upper(p_sede);
begin
 if auth.uid() is null or not public.usuario_es_admin_sede(p_sede) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 if s not in('SPS','CBA','SRC') then raise exception 'SEDE_INVALIDA'; end if;
 if p_rol not in('admin','consulta') then raise exception 'ROL_INVALIDO'; end if;
 select id into uid from auth.users where lower(email)=em;
 if uid is null then raise exception 'USUARIO_AUTH_NO_EXISTE_USE_CONTRASENA'; end if;
 insert into public.usuarios_sedes(user_id,email,nombre,sede,rol,puede_cierre_dia,activo,updated_at)
 values(uid,em,nullif(trim(coalesce(p_nombre,'')),''),s,p_rol,coalesce(p_puede_cierre,false),true,now())
 on conflict(user_id,sede) do update set email=excluded.email,nombre=coalesce(excluded.nombre,public.usuarios_sedes.nombre),rol=excluded.rol,puede_cierre_dia=excluded.puede_cierre_dia,activo=true,updated_at=now();
 return true;
end $function$;

CREATE OR REPLACE FUNCTION public.master_cambiar_estado_acceso(p_user_id uuid, p_sede text, p_activo boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 if auth.uid() is null or not public.usuario_es_admin_sede(p_sede) then raise exception 'SOLO_ADMINISTRADOR_SEDE'; end if;
 update public.usuarios_sedes set activo=p_activo,updated_at=now() where user_id=p_user_id and sede=upper(p_sede);
 if not found then raise exception 'ACCESO_NO_ENCONTRADO'; end if;
 return true;
end $function$;
 
notify pgrst,'reload schema';
