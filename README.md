BIA HONDURAS - PWA v2.1

CORRECCIÓN
Se solucionó el error:
Could not find the function public.iniciar_actividad_compartida(...) in the schema cache.

CAMBIO APLICADO
La PWA ahora usa la función:
public.iniciar_actividad_v2(uuid[], jsonb)

Esta función sirve para:
- Actividades individuales: exactamente un colaborador.
- Preparación de Walmart: dos o más colaboradores.
- Preparación de La Colonia: dos o más colaboradores.
- Carga de Contenedores: dos o más colaboradores.
- Descarga de Contenedores: dos o más colaboradores.

INSTALACIÓN
1. En Supabase, abra SQL Editor.
2. Ejecute:
   actualizacion_v2_1_corregir_inicio_actividades.sql
3. Compruebe que el resultado final muestre:
   iniciar_actividad_v2 | p_colaborador_ids uuid[], p_datos jsonb
4. Reemplace todos los archivos publicados por esta versión.
5. Cierre completamente la PWA o elimínela y vuelva a instalarla.
6. Abra nuevamente la aplicación.

IMPORTANTE
El SQL incluye:
notify pgrst, 'reload schema';
para obligar a Supabase a actualizar la caché de funciones.
