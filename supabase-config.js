// supabase-config.js
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.38.0/+esm';

export const SUPABASE_URL = 'https://czxzghhwgfciyrgmgtai.supabase.co';
export const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN6eHpnaGh3Z2ZjaXlyZ21ndGFpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMxNzYxMTgsImV4cCI6MjA4ODc1MjExOH0.LdODWE1RDggRq11NkfgFTUVv6g1E5iQxTfOtZnV0gF0';

// Cliente principal
export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
    }
});

// Verificar conexión básica
export async function verificarConexion() {
    try {
        const { error } = await supabase.from('usuarios').select('id').limit(1);
        if (error) throw error;
        console.log('✓ Conexión a Supabase exitosa');
        return true;
    } catch (error) {
        console.error('✗ Error de conexión:', error);
        return false;
    }
}

// Iniciar sesión real en Supabase Auth
export async function iniciarSesion(email, password) {
    try {
        const { data, error } = await supabase.auth.signInWithPassword({
            email,
            password
        });

        if (error) throw error;

        console.log('✓ Sesión iniciada correctamente');
        return {
            ok: true,
            session: data.session,
            user: data.user
        };
    } catch (error) {
        console.error('✗ Error al iniciar sesión:', error.message);
        return {
            ok: false,
            error: error.message
        };
    }
}

// Cerrar sesión
export async function cerrarSesion() {
    try {
        const { error } = await supabase.auth.signOut();
        if (error) throw error;

        console.log('✓ Sesión cerrada correctamente');
        return { ok: true };
    } catch (error) {
        console.error('✗ Error al cerrar sesión:', error.message);
        return {
            ok: false,
            error: error.message
        };
    }
}

// Obtener sesión actual
export async function obtenerSesion() {
    try {
        const { data, error } = await supabase.auth.getSession();
        if (error) throw error;

        return {
            ok: true,
            session: data.session
        };
    } catch (error) {
        console.error('✗ Error al obtener sesión:', error.message);
        return {
            ok: false,
            error: error.message,
            session: null
        };
    }
}

// Obtener usuario actual
export async function obtenerUsuarioActual() {
    try {
        const { data, error } = await supabase.auth.getUser();
        if (error) throw error;

        return {
            ok: true,
            user: data.user
        };
    } catch (error) {
        console.error('✗ Error al obtener usuario actual:', error.message);
        return {
            ok: false,
            error: error.message,
            user: null
        };
    }
}

// Escuchar cambios de autenticación
export function escucharCambiosSesion(callback) {
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
        console.log('Cambio de sesión:', event);
        if (typeof callback === 'function') {
            callback(event, session);
        }
    });

    return data.subscription;
}
