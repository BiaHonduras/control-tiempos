CREATE OR REPLACE FUNCTION public.guardar_ausencia_sede_v1(p_colaborador_id uuid, p_fecha date, p_horas_ausencia numeric, p_tipo_ausencia text, p_motivo text, p_sede text)
 RETURNS ausencias_personal
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n text;em text;j numeric;v public.ausencias_personal;s text:=upper(p_sede);begin
 if not public.bia_can('tiempos','write',p_sede) then raise exception 'PERMISO_INSUFICIENTE';end if;
 if not public.usuario_es_admin_sede(s) then raise exception 'SOLO_ADMINISTRADOR_SEDE';end if;select nombre into n from public.colaboradores where id=p_colaborador_id and sede=s;if n is null then raise exception 'COLABORADOR_NO_ENCONTRADO';end if;j=public.horas_jornada_fecha(p_fecha);if j<=0 then raise exception 'DIA_SIN_JORNADA';end if;if p_horas_ausencia<=0 or p_horas_ausencia>j then raise exception 'HORAS_AUSENCIA_INVALIDAS';end if;select email into em from auth.users where id=auth.uid();
 insert into public.ausencias_personal(colaborador_id,colaborador_nombre,fecha,horas_ausencia,motivo,tipo_ausencia,registrado_por,registrado_por_email,updated_at,sede) values(p_colaborador_id,n,p_fecha,p_horas_ausencia,nullif(trim(coalesce(p_motivo,'')),''),coalesce(nullif(trim(p_tipo_ausencia),''),'Ausencia'),auth.uid(),em,now(),s)
 on conflict(colaborador_id,fecha) do update set horas_ausencia=excluded.horas_ausencia,motivo=excluded.motivo,tipo_ausencia=excluded.tipo_ausencia,registrado_por=auth.uid(),registrado_por_email=em,updated_at=now(),sede=s returning * into v;return v;end $function$;


NOTIFY pgrst, 'reload schema';
