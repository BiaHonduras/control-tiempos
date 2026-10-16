-- Expand existing site checks without altering other predicates.
DO $sites$
DECLARE c record; p record; definition text;
BEGIN
 FOR c IN SELECT pc.conrelid,pc.conname,pg_get_constraintdef(pc.oid) definition
 FROM pg_constraint pc JOIN pg_namespace n ON n.oid=pc.connamespace
 WHERE n.nspname='public' AND pc.contype='c'
 AND pc.conname IN (
 'errores_preparacion_sede_check','usuarios_sedes_sede_check','colaboradores_sede_check',
 'cronometros_sede_check','historial_preparaciones_sede_check','historial_actividades_sede_check',
 'actividad_participaciones_sede_check','preparacion_participaciones_sede_check',
 'ausencias_personal_sede_check','metas_productividad_sede_check','cierres_diarios_sede_check',
 'pausas_cronometros_sede_check','actividades_catalogo_sede_check','auditoria_modificaciones_sede_check',
 'auditoria_eliminaciones_sede_check','auditoria_cierres_dia_sede_check',
 'errores_preparacion_participantes_sede_check','user_profiles_agency_check','supplier_claims_agency_check')
 LOOP
  definition:=replace(c.definition,'ARRAY[''SPS''::text, ''CBA''::text, ''SRC''::text, ''TGU''::text]','ARRAY[''SPS''::text, ''CBA''::text, ''SRC''::text, ''TGU''::text, ''AMT''::text]');
  definition:=replace(definition,'ARRAY[''SPS''::text, ''CBA''::text, ''SRC''::text]','ARRAY[''SPS''::text, ''CBA''::text, ''SRC''::text, ''TGU''::text, ''AMT''::text]');
  IF definition<>c.definition THEN
   EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',c.conrelid::regclass,c.conname);
   EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s',c.conrelid::regclass,c.conname,definition);
  END IF;
 END LOOP;
 -- Keep the functions' existing authentication, authorization and grants.
 FOR p IN SELECT oid,proname FROM pg_proc WHERE pronamespace='public'::regnamespace
 AND proname IN ('master_asignar_usuario_existente','reporte_errores_preparacion_sede_v2','handle_new_user','obtener_sedes_usuario')
 LOOP
  definition:=pg_get_functiondef(p.oid);
  definition:=replace(definition,'''SPS'',''CBA'',''SRC''','''SPS'',''CBA'',''SRC'',''TGU'',''AMT''');
  definition:=replace(definition,'''SPS'', ''CBA'', ''SRC'', ''TGU''','''SPS'', ''CBA'', ''SRC'', ''TGU'', ''AMT''');
  EXECUTE definition;
 END LOOP;
END $sites$;

-- Independent copies of SRC configuration and existing access assignments.
INSERT INTO public.actividades_catalogo(sede,nombre,min_participantes,max_participantes,activo,orden)
SELECT target.sede,src.nombre,src.min_participantes,src.max_participantes,src.activo,src.orden
FROM public.actividades_catalogo src CROSS JOIN (VALUES('TGU'),('AMT')) target(sede)
WHERE src.sede='SRC' AND NOT EXISTS(SELECT 1 FROM public.actividades_catalogo existing WHERE existing.sede=target.sede AND existing.nombre=src.nombre);

INSERT INTO public.metas_productividad(sede,facturas_hora,libras_hora,productividad_minima,actividad_alerta_min,activo)
SELECT target.sede,src.facturas_hora,src.libras_hora,src.productividad_minima,src.actividad_alerta_min,src.activo
FROM public.metas_productividad src CROSS JOIN (VALUES('TGU'),('AMT')) target(sede)
WHERE src.sede='SRC' AND NOT EXISTS(SELECT 1 FROM public.metas_productividad existing WHERE existing.sede=target.sede);

INSERT INTO public.usuarios_sedes(user_id,email,nombre,sede,rol,puede_cierre_dia,activo)
SELECT src.user_id,src.email,src.nombre,target.sede,src.rol,src.puede_cierre_dia,src.activo
FROM public.usuarios_sedes src CROSS JOIN (VALUES('TGU'),('AMT')) target(sede)
WHERE src.sede='SRC' ON CONFLICT(user_id,sede) DO NOTHING;

-- SRC currently has no collaborators; this also supports replay against a seeded installation.
INSERT INTO public.colaboradores(nombre,codigo,activo,orden,sede)
SELECT src.nombre,src.codigo,src.activo,src.orden,target.sede
FROM public.colaboradores src CROSS JOIN (VALUES('TGU'),('AMT')) target(sede)
WHERE src.sede='SRC' AND NOT EXISTS(SELECT 1 FROM public.colaboradores existing WHERE existing.sede=target.sede AND existing.nombre=src.nombre AND existing.codigo IS NOT DISTINCT FROM src.codigo);
