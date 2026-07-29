BIA HONDURAS - CONTROL DE TIEMPOS PWA v1.6

NUEVA FUNCIÓN
Los administradores pueden eliminar registros del historial de:
- Preparación de pedidos.
- Actividades.

SEGURIDAD
- El botón Eliminar solo se muestra a usuarios con rol admin.
- La eliminación se ejecuta mediante una función segura en Supabase.
- Se solicita un motivo obligatorio.
- Antes de borrar, Supabase guarda una copia completa en:
  public.auditoria_eliminaciones
- La auditoría registra administrador, correo, motivo y fecha.
- Los operadores no tienen permisos para eliminar.

INSTALACIÓN
1. Publique todos los archivos de esta carpeta.
2. Ejecute en Supabase SQL Editor:
   actualizacion_v1_6_eliminar_registros_admin.sql
3. Cierre y vuelva a abrir la PWA.
4. Inicie sesión con un usuario administrador.
5. En cada historial aparecerá la columna Acciones con el botón Eliminar.

IMPORTANTE
No se elimina el cronómetro técnico original de la tabla cronometros.
Solo se retira el registro visible del historial y se conserva la auditoría.
