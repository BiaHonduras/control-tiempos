import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const authHeader = req.headers.get('Authorization') || ''
    const token = authHeader.replace('Bearer ', '')
    if (!token) throw new Error('AUTH_REQUIRED')

    const url = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken:false, persistSession:false } })
    const { data: callerData, error: callerError } = await admin.auth.getUser(token)
    if (callerError || !callerData.user) throw new Error('AUTH_REQUIRED')
    if ((callerData.user.email || '').toLowerCase() !== 'javierh@biabrands.co') throw new Error('SOLO_USUARIO_MAESTRO')

    const body = await req.json()
    if (body.action !== 'create_or_assign') throw new Error('ACCION_INVALIDA')
    const email = String(body.email || '').trim().toLowerCase()
    const nombre = String(body.nombre || '').trim()
    const sede = String(body.sede || '').toUpperCase()
    const rol = String(body.rol || 'consulta')
    const password = String(body.password || '')
    if (!email.includes('@')) throw new Error('EMAIL_INVALIDO')
    if (!['SPS','CBA','SRC'].includes(sede)) throw new Error('SEDE_INVALIDA')
    if (!['admin','consulta'].includes(rol)) throw new Error('ROL_INVALIDO')

    let user:any = null
    let created = false
    for (let page=1; page<=20 && !user; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 })
      if (error) throw error
      user = data.users.find(u => (u.email || '').toLowerCase() === email)
      if (data.users.length < 100) break
    }
    if (!user) {
      if (password.length < 8) throw new Error('CONTRASENA_MINIMO_8')
      const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm:true, user_metadata:{ nombre } })
      if (error) throw error
      user = data.user; created = true
    }
    const { error: upsertError } = await admin.from('usuarios_sedes').upsert({
      user_id:user.id,email,nombre,sede,rol,puede_cierre_dia:!!body.puede_cierre_dia,activo:true,updated_at:new Date().toISOString()
    }, { onConflict:'user_id,sede' })
    if (upsertError) throw upsertError
    return new Response(JSON.stringify({ok:true,created,user_id:user.id}), { headers:{...corsHeaders,'Content-Type':'application/json'} })
  } catch (e) {
    return new Response(JSON.stringify({error:String(e?.message || e)}), { status:400, headers:{...corsHeaders,'Content-Type':'application/json'} })
  }
})
