import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.0'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'METODO_NO_PERMITIDO' }, 405)

  try {
    const authHeader = req.headers.get('Authorization') || ''
    const token = authHeader.replace(/^Bearer\s+/i, '').trim()
    if (!token) return json({ error: 'AUTH_REQUIRED' }, 401)

    const url = Deno.env.get('SUPABASE_URL') || ''
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
    if (!url || !serviceKey) return json({ error: 'EDGE_CONFIG_INCOMPLETA', message: 'Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY.' }, 500)

    const admin = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })

    const { data: callerData, error: callerError } = await admin.auth.getUser(token)
    if (callerError || !callerData.user) return json({ error: 'AUTH_REQUIRED', message: callerError?.message || 'Sesión no válida.' }, 401)

    const callerEmail = (callerData.user.email || '').trim().toLowerCase()
    if (callerEmail !== 'javierh@biabrands.co') return json({ error: 'SOLO_USUARIO_MAESTRO' }, 403)

    let body: any = null
    try { body = await req.json() } catch { return json({ error: 'JSON_INVALIDO' }, 400) }
    if (body?.action !== 'create_or_assign') return json({ error: 'ACCION_INVALIDA' }, 400)

    const email = String(body.email || '').trim().toLowerCase()
    const nombre = String(body.nombre || '').trim()
    const sede = String(body.sede || '').trim().toUpperCase()
    const rol = String(body.rol || 'consulta').trim().toLowerCase()
    const password = String(body.password || '')

    if (!email || !email.includes('@')) return json({ error: 'EMAIL_INVALIDO' }, 400)
    if (!['SPS', 'CBA', 'SRC'].includes(sede)) return json({ error: 'SEDE_INVALIDA' }, 400)
    if (!['admin', 'consulta'].includes(rol)) return json({ error: 'ROL_INVALIDO' }, 400)

    let user: any = null
    for (let page = 1; page <= 100 && !user; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 })
      if (error) return json({ error: 'AUTH_LIST_USERS', message: error.message }, 500)
      user = data.users.find((u) => (u.email || '').trim().toLowerCase() === email) || null
      if (data.users.length < 100) break
    }

    let created = false
    if (!user) {
      if (password.length < 8) return json({ error: 'CONTRASENA_MINIMO_8' }, 400)
      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { nombre },
      })
      if (error) return json({ error: 'AUTH_CREATE_USER', message: error.message }, 400)
      user = data.user
      created = true
    }

    if (!user?.id) return json({ error: 'USER_ID_NO_DISPONIBLE' }, 500)

    const { error: upsertError } = await admin.from('usuarios_sedes').upsert({
      user_id: user.id,
      email,
      nombre: nombre || null,
      sede,
      rol,
      puede_cierre_dia: !!body.puede_cierre_dia,
      activo: true,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id,sede' })

    if (upsertError) {
      return json({ error: 'USUARIOS_SEDES_UPSERT', message: upsertError.message, details: upsertError.details || null }, 400)
    }

    return json({ ok: true, created, user_id: user.id, email, sede, rol })
  } catch (e) {
    console.error('admin-users unexpected error', e)
    return json({ error: 'EDGE_UNEXPECTED', message: String((e as any)?.message || e) }, 500)
  }
})
