# NAVE CRM — puesta en marcha

CRM modo lanzamiento (escala 3k–10k leads, 15+ asesores). App estática + Supabase, deploy en Vercel.

## Archivos
- `index.html` — la app (login + shell + módulo Leads con import/auto-reparto/paginación).
- `schema.sql` — la base de datos (pegar en Supabase).

---

## Paso 1 · Supabase
1. Creá un proyecto en **https://supabase.com** (gratis).
2. **SQL Editor → New query** → pegá TODO el contenido de `schema.sql` → **Run**.
3. **Authentication → Providers → Email:** dejá habilitado *Email*. Para probar rápido, en **Authentication → Providers → Email** podés desactivar "Confirm email" (así entrás sin confirmar por mail).

## Paso 2 · Conectar la app
1. **Project Settings → API:** copiá **Project URL** y **anon public key**.
2. Abrí `index.html` y completá arriba del `<script>`:
```js
const SUPABASE_URL = 'https://TU-PROYECTO.supabase.co'
const SUPABASE_ANON_KEY = 'eyJhbGciOi...'
```

## Paso 3 · Crear tu usuario y hacerte manager
1. Abrí la app (local o deployada) → **Crear una** cuenta con tu email/contraseña.
2. En Supabase → **Table Editor → profiles** → tu fila → cambiá `rol` a **manager**. (Así ves todos los leads y podés auto-repartir.)
3. Cada asesor se crea su cuenta igual; vos les dejás el rol `setter` (o `closer`).

## Paso 4 · Deploy a Vercel
**Opción GitHub (recomendada):** subí `index.html` a un repo → vercel.com → *Add New → Project → Import* → Framework: **Other** → Deploy. Listo, URL para el equipo.
**Vercel CLI:** `npm i -g vercel && vercel` (requiere Node).

---

## Qué funciona (TODO cableado)
- **Login por usuario** (Supabase Auth) + **roles** (setter / closer / manager). RLS: el asesor ve lo suyo; el manager, todo.
- **Panel general:** embudo del lanzamiento en vivo + tu cola de **seguimientos de hoy** + resumen de cobros.
- **Leads a escala:** tabla con búsqueda, filtros ("mis leads", temperatura, estado) y **paginación server-side** (aguanta 10k).
- **Import CSV** con mapeo de columnas, **dedup** y **auto-reparto** round-robin entre asesores.
- **Lead** con **asistencia por clase (1/2/3)** y creación de **seguimientos** (fecha + nota).
- **KPIs diarios:** carga del día (upsert) + historial.
- **Triage:** cola de agendas para preparar antes de la call.
- **Reporte de llamadas:** formulario completo; si el lead cierra, **genera las cuotas** automáticamente (upfront cobrado + resto en 2/3 cuotas), actualiza el estado del lead y crea el próximo seguimiento. Conversión FX con la última cotización cargada.
- **Grilla de reportes:** tabla + detalle por reporte.
- **Marketing:** puntos de contacto (alta + KPIs) + leads por plataforma.
- **Cobros:** tabs, KPIs (cobrado / al día / vencidas / upsell / total), carga de cuota manual y **marcar cobrada**.
- **Calendario:** agenda de clases + seguimientos por día.

### Notas
- **Cotizaciones FX:** para que ARS/EUR conviertan bien, cargá filas en la tabla `cotizaciones_fx` (moneda, valor, fecha). Si no hay, usa 1:1.
- **Programas:** opcional, para el autocompletado en el reporte — cargá filas en `programas`.
- Todo probado a nivel de que **la app bootea sin errores**; el flujo con datos reales se prueba con tu Supabase. Si algo tira error, mandámelo y lo corrijo.
