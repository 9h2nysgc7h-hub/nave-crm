// Recibe el webhook "invitee.created" de Calendly y carga/actualiza la agenda
// en Supabase, igual que hace saveAgenda() en el CRM (misma lógica de dedup_key,
// lanzamiento activo, y registro en "seguimientos").
//
// Variables de entorno necesarias en Vercel:
//   SUPABASE_URL                -> la misma URL que usa el CRM
//   SUPABASE_SERVICE_ROLE_KEY   -> Project Settings > API > service_role (NO la anon key)
//   CALENDLY_SIGNING_SECRET     -> te la da Calendly al crear la webhook subscription

const crypto = require('crypto')

module.exports.config = { api: { bodyParser: false } }

function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

function verifySignature(rawBody, header, secret) {
  if (!header) return false
  const parts = Object.fromEntries(
    header.split(',').map((p) => p.split('=').map((s) => s.trim()))
  )
  if (!parts.t || !parts.v1) return false
  const expected = crypto
    .createHmac('sha256', secret)
    .update(`${parts.t}.${rawBody.toString('utf8')}`)
    .digest('hex')
  const a = Buffer.from(expected, 'hex')
  const b = Buffer.from(parts.v1, 'hex')
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

async function sb(path, opts = {}) {
  const res = await fetch(`${process.env.SUPABASE_URL}/rest/v1/${path}`, {
    ...opts,
    headers: {
      apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: opts.prefer || 'return=representation',
      ...(opts.headers || {}),
    },
  })
  if (!res.ok) throw new Error(`Supabase ${path} -> ${res.status}: ${await res.text()}`)
  const text = await res.text()
  return text ? JSON.parse(text) : null
}

function normalizarClave(s) {
  return s ? s.toLowerCase().replace(/[^a-z0-9]/g, '') : null
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).send('Method not allowed')

  const rawBody = await readRawBody(req)

  if (!verifySignature(rawBody, req.headers['calendly-webhook-signature'], process.env.CALENDLY_SIGNING_SECRET)) {
    return res.status(400).send('Firma inválida')
  }

  let body
  try {
    body = JSON.parse(rawBody.toString('utf8'))
  } catch {
    return res.status(400).send('JSON inválido')
  }

  if (body.event !== 'invitee.created') {
    return res.status(200).send('Evento ignorado')
  }

  try {
    const p = body.payload
    const nombre = p.name || 'Sin nombre'
    const email = p.email || null
    const telefono = p.text_reminder_number || null
    const utmSetter = (p.tracking && p.tracking.utm_source || '').trim().toLowerCase()
    const fechaAgenda = p.scheduled_event && p.scheduled_event.start_time
      ? p.scheduled_event.start_time.slice(0, 10)
      : null
    // Calendly ya resolvió el round robin acá mismo: el closer asignado a
    // esta llamada puntual viene en scheduled_event.event_memberships.
    const memberships = (p.scheduled_event && p.scheduled_event.event_memberships) || []
    const closerEmail = memberships[0] && memberships[0].user_email ? memberships[0].user_email.trim() : null

    const [lanzs, setters, closerRows] = await Promise.all([
      sb('lanzamientos?select=id&activo=eq.true&limit=1'),
      sb('profiles?select=id,nombre&rol=eq.setter&activo=eq.true'),
      closerEmail
        ? sb(`profiles?select=id&email=ilike.${encodeURIComponent(closerEmail)}&limit=1`)
        : Promise.resolve(null),
    ])
    const lanzamiento_id = lanzs && lanzs[0] ? lanzs[0].id : null
    const closer_id = closerRows && closerRows[0] ? closerRows[0].id : null

    // Prioridad 1: UTM del link personalizado del setter
    let asesor_id = null
    if (utmSetter) {
      const match = (setters || []).find((s) => {
        const n = (s.nombre || '').toLowerCase()
        return n === utmSetter || n.split(' ')[0] === utmSetter || n.includes(utmSetter)
      })
      if (match) asesor_id = match.id
    }

    const dedup_key = normalizarClave(telefono) || normalizarClave(email)

    // ¿Este teléfono ya es un lead en el lanzamiento activo? (decide update vs insert)
    let existenteEnLanz = null
    if (dedup_key) {
      const rows = await sb(
        `leads?select=id,asesor_id&dedup_key=eq.${dedup_key}&lanzamiento_id=eq.${lanzamiento_id}&limit=1`
      )
      existenteEnLanz = rows && rows[0]
    }

    // Prioridad 2: sin UTM (o UTM sin match), respetar al asesor dueño de ese
    // teléfono en la base — el del lanzamiento activo si ya existe, o si no,
    // el último lead con ese teléfono en cualquier lanzamiento que tenga asesor.
    if (!asesor_id && dedup_key) {
      if (existenteEnLanz && existenteEnLanz.asesor_id) {
        asesor_id = existenteEnLanz.asesor_id
      } else {
        const base = await sb(
          `leads?select=asesor_id&dedup_key=eq.${dedup_key}&asesor_id=not.is.null&order=updated_at.desc&limit=1`
        )
        if (base && base[0]) asesor_id = base[0].asesor_id
      }
    }

    const patch = {
      nombre,
      telefono,
      email,
      fuente: 'calendly',
      temperatura: 'leve',
      estado: 'Agendó',
      asesor_id,
      lanzamiento_id,
      dedup_key,
      updated_at: new Date().toISOString(),
    }

    let leadId
    if (dedup_key) {
      if (existenteEnLanz) {
        const r = await sb(`leads?id=eq.${existenteEnLanz.id}`, { method: 'PATCH', body: JSON.stringify(patch) })
        leadId = r[0].id
      } else {
        const r = await sb('leads', { method: 'POST', body: JSON.stringify(patch) })
        leadId = r[0].id
      }
    } else {
      const r = await sb('leads', { method: 'POST', body: JSON.stringify(patch) })
      leadId = r[0].id
    }

    if (fechaAgenda) {
      await sb('seguimientos', {
        method: 'POST',
        body: JSON.stringify({
          lead_id: leadId,
          asesor_id,
          closer_id,
          fecha_programada: fechaAgenda,
          tipo: 'agenda',
          nota: 'Agendado vía Calendly (automático)',
        }),
      })
    }

    return res.status(200).send('OK')
  } catch (err) {
    console.error('calendly-webhook error', err)
    return res.status(500).send('Error interno')
  }
}
