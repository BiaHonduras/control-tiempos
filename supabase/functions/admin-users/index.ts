import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.0'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function passwordValid(password: string) { return password.length >= 8 && /[a-z]/.test(password) && /[A-Z]/.test(password) && /[0-9]/.test(password) && /[^a-zA-Z0-9]/.test(password) }

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


    let body: any = null
    try { body = await req.json() } catch { return json({ error: 'JSON_INVALIDO' }, 400) }
    if (body?.action === 'change_own_password') {
      const password = String(body.password || '')
      if (!passwordValid(password)) return json({error:'CONTRASENA_INVALIDA',message:'La contraseña debe tener al menos 8 caracteres, mayúscula, minúscula, número y símbolo.'},400)
      const { error } = await admin.auth.admin.updateUserById(callerData.user.id, {
        password, app_metadata: { ...callerData.user.app_metadata, must_change_password: false },
      })
      if (error) return json({error:'AUTH_UPDATE_PASSWORD',message:error.message},400)
      return json({ok:true})
    }
    return json({error:'GESTION_DE_USUARIOS_EN_INTRANET',message:'Gestiona usuarios desde la Intranet BIA Honduras.'},410)
  } catch (error) { return json({error:'OPERACION_NO_COMPLETADA'},400) }
})
