-- Prueba de integración con cuentas y registros sintéticos. Siempre hace ROLLBACK.
begin;
do $$
declare a uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); x uuid:=gen_random_uuid();
 t uuid:=gen_random_uuid(); h uuid:=gen_random_uuid(); p jsonb; n bigint; em text; col uuid;
begin
 insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values
 (a,a::text||'@delete-test.invalid','{}','{}'),(u,u::text||'@delete-test.invalid','{}','{}'),
 (r,r::text||'@delete-test.invalid','{}','{}'),(x,x::text||'@delete-test.invalid','{}','{}');
 insert into public.usuarios_sedes(user_id,email,sede,rol,activo) values
 (a,a::text||'@delete-test.invalid','SPS','admin',true),
 (u,u::text||'@delete-test.invalid','SPS','consulta',true),
 (r,r::text||'@delete-test.invalid','SPS','consulta',true),
 (x,x::text||'@delete-test.invalid','CBA','consulta',true);
 em:=u::text||'@delete-test.invalid';
 insert into public.cronometros(id,categoria,empleado,iniciado_por,actualizado_por,sede,segundos_acumulados)
 values(t,'actividad','Integración eliminación',u,u,'SPS',123);
 insert into public.historial_actividades(id,timer_id,fecha,empleado,actividad,segundos,finalizado_por,finalizado_por_email,sede)
 values(h,t,current_date,'Integración eliminación','Aseo Almacén',123,u,em,'SPS');
 insert into public.pausas_cronometros(cronometro_id,motivo,pausado_por,pausado_por_email,sede)
 values(t,'Prueba',u,em,'SPS');
 p:=public.admin_eliminar_usuario_completo_v1(a,u,'SPS');
 if p->>'email'<>em or jsonb_array_length(p->'sedes')<>1 then raise exception 'PREVIEW_FAILED'; end if;
 -- Confirmación obligatoria.
 begin
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',r),false);
  raise exception 'CONFIRMATION_NOT_ENFORCED';
 exception when raise_exception then if sqlerrm<>'CONFIRMACION_REQUERIDA' then raise; end if; end;
 -- El propio usuario no puede ser receptor.
 begin
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',u),true);
  raise exception 'SELF_RECIPIENT_ALLOWED';
 exception when raise_exception then if sqlerrm not like 'RECEPTOR_INVALIDO%' then raise; end if; end;
 -- Un usuario de otra sede tampoco.
 begin
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',x),true);
  raise exception 'CROSS_SITE_RECIPIENT_ALLOWED';
 exception when raise_exception then if sqlerrm not like 'RECEPTOR_INVALIDO%' then raise; end if; end;
 -- Un usuario de consulta no puede solicitar eliminaciones.
 begin
  perform public.admin_eliminar_usuario_completo_v1(r,u,'SPS');
  raise exception 'VIEWER_ALLOWED';
 exception when raise_exception then if sqlerrm not like 'SOLO_ADMINISTRADOR_SEDE%' then raise; end if; end;
 -- Falta de otro usuario en la sede: todo dentro de una subtransacción revertida.
 begin
  update public.usuarios_sedes set activo=false where sede='SPS' and user_id<>u;
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS');
  raise exception 'MINIMUM_NOT_ENFORCED';
 exception when raise_exception then
  -- El actor admin quedó inactivo: utilizar un maestro real para probar el mínimo.
  if sqlerrm not like 'SOLO_ADMINISTRADOR_SEDE%' then raise; end if;
 end;
 declare m uuid; begin
  select id into m from auth.users where lower(email) in ('javierh@biabrands.co','fesicars@gmail.com')
   and coalesce(raw_app_meta_data->>'must_change_password','false')<>'true' limit 1;
  if m is null then raise exception 'NO_MASTER_TEST_CONTEXT'; end if;
  begin
   update public.usuarios_sedes set activo=false where sede='SPS' and user_id<>u;
   perform public.admin_eliminar_usuario_completo_v1(m,u,'SPS');
   raise exception 'MINIMUM_NOT_ENFORCED';
  exception when raise_exception then if sqlerrm not like 'SIN_OTRO_USUARIO%' then raise; end if; end;
 end;
 -- Receptor inactivo también se rechaza.
 begin
  update public.usuarios_sedes set activo=false where user_id=r;
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',r),true);
  raise exception 'INACTIVE_RECIPIENT_ALLOWED';
 exception when raise_exception then if sqlerrm not like 'RECEPTOR_INVALIDO%' then raise; end if; end;
 -- Cuenta con varias sedes: exige receptor y permisos para cada una.
 insert into public.usuarios_sedes(user_id,email,sede,rol,activo) values(u,em,'CBA','consulta',true);
 begin
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS');
  raise exception 'MISSING_SITE_PERMISSION_ALLOWED';
 exception when raise_exception then if sqlerrm not like 'SOLO_ADMINISTRADOR_SEDE%' then raise; end if; end;
 insert into public.usuarios_sedes(user_id,email,sede,rol,activo) values(a,a::text||'@delete-test.invalid','CBA','admin',true);
 p:=public.admin_eliminar_usuario_completo_v1(a,u,'SPS');
 if jsonb_array_length(p->'sedes')<>2 then raise exception 'MULTI_SITE_PREVIEW_FAILED'; end if;
 begin
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',r),true);
  raise exception 'MISSING_SITE_RECIPIENT_ALLOWED';
 exception when raise_exception then if sqlerrm not like 'RECEPTOR_INVALIDO%' then raise; end if; end;
 delete from public.usuarios_sedes where user_id=u and sede='CBA';
 -- Una referencia imprevista aborta la transacción completa, incluidos los traspasos.
 create table control_tiempos_privado.delete_test_guard(user_id uuid references auth.users(id));
 insert into control_tiempos_privado.delete_test_guard values(u);
 begin
  perform public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',r),true);
  raise exception 'UNEXPECTED_REFERENCE_IGNORED';
 exception when raise_exception then if sqlerrm not like 'REFERENCIAS_SIN_TRASPASAR%' then raise; end if; end;
 if not exists(select 1 from public.cronometros where id=t and iniciado_por=u and actualizado_por=u)
  or not exists(select 1 from auth.users where id=u)
  or exists(select 1 from control_tiempos_privado.traspasos_usuarios where origen_id=u)
 then raise exception 'ATOMIC_ROLLBACK_FAILED'; end if;
 delete from control_tiempos_privado.delete_test_guard;
 -- Operación positiva: conserva registros y tiempo; elimina la cuenta y sus accesos.
 p:=public.admin_eliminar_usuario_completo_v1(a,u,'SPS',jsonb_build_object('SPS',r),true);
 if p->>'deleted'<>'true' then raise exception 'DELETE_FAILED'; end if;
 if exists(select 1 from auth.users where id=u) or exists(select 1 from public.usuarios_sedes where user_id=u)
  or exists(select 1 from public.user_profiles where id=u) then raise exception 'ACCOUNT_NOT_DELETED'; end if;
 if not exists(select 1 from public.cronometros where id=t and iniciado_por=r and actualizado_por=r and segundos_acumulados=123)
 then raise exception 'TIMER_TRANSFER_FAILED'; end if;
 if not exists(select 1 from public.historial_actividades where id=h and finalizado_por=r and finalizado_por_email=r::text||'@delete-test.invalid' and segundos=123)
 then raise exception 'HISTORY_TRANSFER_FAILED'; end if;
 if not exists(select 1 from public.pausas_cronometros where cronometro_id=t and pausado_por=r and pausado_por_email=r::text||'@delete-test.invalid')
 then raise exception 'PAUSE_TRANSFER_FAILED'; end if;
 if not exists(select 1 from control_tiempos_privado.traspasos_usuarios where origen_id=u and origen_email=em)
 then raise exception 'AUDIT_FAILED'; end if;
 if has_function_privilege('authenticated','public.admin_eliminar_usuario_completo_v1(uuid,uuid,text,jsonb,boolean)','execute')
  or has_function_privilege('anon','public.admin_eliminar_usuario_completo_v1(uuid,uuid,text,jsonb,boolean)','execute')
 then raise exception 'UNTRUSTED_CALLER_CAN_FORGE_ACTOR'; end if;
end $$;
rollback;
select 'PASS: confirmación, permisos, receptor, mínimo, traspaso y eliminación; sin cambios reales' as resultado;
