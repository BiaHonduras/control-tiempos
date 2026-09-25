BIA HONDURAS · PWA v3.0.6
GRÁFICOS NATIVOS DE EXCEL

CAMBIO PRINCIPAL
Los gráficos de la hoja "Dashboard Ejecutivo" ya no se insertan como imágenes PNG.
Ahora se crean como gráficos reales de Excel (OOXML), vinculados a rangos internos del libro.

GRÁFICOS ACTUALIZADOS
1. Productividad por colaborador
   - Barra horizontal real.
   - Rango del eje: 0% a 100%.
   - Hasta 10 colaboradores.
2. Distribución de horas-hombre
   - Gráfico de dona real.
   - Hasta 10 actividades.
3. Tendencia diaria de preparación
   - Gráfico de línea real.
   - Incluye TODOS los días del rango seleccionado, incluso días con 0 facturas.
   - Eje vertical parte de 0 y usa un máximo redondeado.
4. Ausencias por colaborador
   - Barra horizontal real.
   - Rango vertical/horizontal ajustado a las horas registradas.

DATOS DE LOS GRÁFICOS
Se crea una hoja "Datos Dashboard" en estado VeryHidden. Los gráficos apuntan a rangos reales de esa hoja.
En Excel se pueden seleccionar los gráficos, cambiar estilos, colores, títulos, ejes y revisar el origen de datos.

IMPORTANTE
- No requiere SQL adicional.
- Incluye vendor/jszip.min.js localmente para convertir el libro generado por ExcelJS en un XLSX con gráficos nativos.
- Reemplazar TODOS los archivos del sitio/PWA y hacer Ctrl+F5.
- En Android cerrar por completo la PWA y abrir nuevamente.
