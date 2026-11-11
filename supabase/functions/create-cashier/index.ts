import { createClient } from 'npm:@supabase/supabase-js@2'

const siteOrigin = Deno.env.get('SITE_ORIGIN') ?? 'https://denverufb.github.io'

function corsHeaders(origin: string | null) {
  return {
    'Access-Control-Allow-Origin': origin === siteOrigin ? origin : siteOrigin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  }
}

function response(origin: string | null, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (request) => {
  const origin = request.headers.get('Origin')
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(origin) })
  if (request.method !== 'POST') return response(origin, 405, { error: 'POST required' })
  if (origin && origin !== siteOrigin) return response(origin, 403, { error: 'Origin not allowed' })

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const authorization = request.headers.get('Authorization')
  if (!supabaseUrl || !serviceRoleKey) return response(origin, 500, { error: 'Server configuration missing' })
  if (!authorization?.startsWith('Bearer ')) return response(origin, 401, { error: 'Sign in required' })

  const service = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const token = authorization.slice('Bearer '.length)
  const { data: userResult, error: userError } = await service.auth.getUser(token)
  if (userError || !userResult.user) return response(origin, 401, { error: 'Session is not valid' })

  const { data: caller, error: callerError } = await service
    .from('staff').select('role,active').eq('id', userResult.user.id).single()
  if (callerError || !caller?.active || caller.role !== 'admin') {
    return response(origin, 403, { error: 'Administrator only' })
  }

  let input: { display_name?: unknown; email?: unknown; password?: unknown }
  try { input = await request.json() } catch { return response(origin, 400, { error: 'Invalid request' }) }
  const displayName = String(input.display_name ?? '').trim()
  const email = String(input.email ?? '').trim().toLowerCase()
  const password = String(input.password ?? '')
  if (displayName.length < 2 || displayName.length > 100) {
    return response(origin, 400, { error: 'Enter a cashier name from 2 to 100 characters' })
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    return response(origin, 400, { error: 'Enter a valid login email' })
  }
  if (password.length < 12 || password.length > 72) {
    return response(origin, 400, { error: 'Temporary password must be 12 to 72 characters' })
  }

  const { count, error: countError } = await service
    .from('staff').select('id', { count: 'exact', head: true }).eq('role', 'staff').eq('active', true)
  if (countError) return response(origin, 500, { error: 'Could not check cashier capacity' })
  if ((count ?? 0) >= 15) return response(origin, 409, { error: 'All 15 active cashier slots are in use' })

  const { data: created, error: createError } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { display_name: displayName, must_change_password: true },
  })
  if (createError || !created.user) {
    const message = /already|registered|exists/i.test(createError?.message ?? '')
      ? 'A Supabase Auth account already uses that email'
      : (createError?.message ?? 'Could not create the Auth account')
    return response(origin, 400, { error: message })
  }

  const { error: staffError } = await service.from('staff').insert({
    id: created.user.id,
    display_name: displayName,
    email,
    active: true,
    role: 'staff',
  })
  if (staffError) {
    await service.auth.admin.deleteUser(created.user.id)
    return response(origin, 400, { error: staffError.message })
  }

  return response(origin, 201, {
    cashier: { id: created.user.id, display_name: displayName, email, active: true },
  })
})
