BIA HONDURAS · PWA v3.1.0

ACTUALIZACIÓN VISUAL / DISEÑO RESPONSIVO

- Retícula equilibrada en escritorio: preparación, actividades y panel lateral usan todo el ancho disponible.
- Los procesos activos ocupan una banda completa y ya no desordenan las columnas.
- Vista adaptable de tres, dos o una columna según el ancho de pantalla.
- Cabecera, indicadores, formularios, fechas y botones ya no se recortan.
- Nuevo favicon e ícono instalable de bodega, en los colores corporativos de BIA Honduras.
- La mejora aplica a SPS, CBA y SRC sin cambiar la lógica de Supabase ni los cronómetros.

BIA HONDURAS · PWA v3.0.2
MÓDULO DE CALIDAD / ERRORES DE PREPARACIÓN

NUEVO
- En Historial de preparaciones, los administradores tienen botón "Errores".
- Se pueden registrar varios errores en una misma preparación.
- Categorías:
  * Faltante de producto
  * Sobrante de producto
  * Producto equivocado
  * Cantidad incorrecta
  * Lote o fecha incorrecta
  * Producto dañado
  * Error de documentación / factura
  * Otro
- El error se asocia únicamente con colaboradores que participaron en esa preparación.
- Cada colaborador recibe un número estable por sede: Colaborador 1, 2, 3...

PRIVACIDAD DEL INFORME
- La app administrativa muestra nombres para poder gestionar y corregir.
- El Excel de calidad NO muestra nombres.
- El reporte anónimo se genera desde Supabase mediante una RPC que no devuelve nombres ni UUID de colaboradores.

EXCEL
Se agregan:
- KPI Preparaciones con error.
- KPI Total de errores.
- KPI Tasa de error.
- Hoja "Calidad Preparación".
- Hoja "Errores Preparación".
- Resumen por Colaborador 1, Colaborador 2, etc.
- Preparaciones asignadas, preparaciones con error, cantidad de errores y porcentaje de error.

SEDES
Todo queda separado por SPS, CBA y SRC.

INSTALACIÓN
1. Ejecutar actualizacion_v3_0_2_errores_preparacion.sql en Supabase.
2. Reemplazar TODOS los archivos web/PWA por esta versión.
3. Ctrl + F5 en web.
4. En Android cerrar completamente la PWA; borrar caché/reinstalar si conserva versión anterior.

NOTA
Los números de colaborador se asignan una sola vez por sede y permanecen estables aunque cambie el nombre del colaborador.

 'iniciar_actividad_v7',
 'iniciar_preparacion_v7',
 'admin_retirar_colaborador_actividad_v2'
)
order by p.proname;
