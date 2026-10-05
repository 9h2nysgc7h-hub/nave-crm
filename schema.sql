-- ============================================================
-- SOUL CRM — Schema (modo lanzamiento, escala 3k–10k leads, 15+ asesores)
-- Pegar en Supabase → SQL Editor → Run.
-- ============================================================

-- ---------- ROLES / USUARIOS ----------
-- profiles cuelga de auth.users (Supabase Auth). Un usuario = un asesor/closer/manager.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text,
  email text,
  rol text not null default 'setter' check (rol in ('setter','closer','manager','admin')),
  activo boolean not null default true,
  created_at timestamptz default now()
);

-- helper: rol del usuario actual (para las políticas RLS)
create or replace function my_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from profiles where id = auth.uid()
$$;
create or replace function is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rol in ('manager','admin') from profiles where id = auth.uid()), false)
$$;

-- ---------- LANZAMIENTOS / CLASES ----------
create table if not exists lanzamientos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  fecha_inicio date,
  activo boolean default true,
  created_at timestamptz default now()
);

create table if not exists clases (
  id uuid primary key default gen_random_uuid(),
  lanzamiento_id uuid references lanzamientos(id) on delete cascade,
  numero int not null,                -- 1, 2, 3
  titulo text,
  fecha timestamptz,
  link text
);

-- ---------- LEADS (núcleo, pensado para volumen) ----------
create table if not exists leads (
  id uuid primary key default gen_random_uuid(),
  lanzamiento_id uuid references lanzamientos(id) on delete set null,
  nombre text not null,
  contacto text,                       -- @ig o whatsapp (texto libre)
  fuente text,                         -- instagram / youtube / ads / otros
  temperatura text default 'potencial' check (temperatura in ('fluido','potencial','leve')),
  estado text default 'Nuevo',         -- Nuevo, Contactado, Confirmó clase, Asistió, Agendó, Cerrado, Perdido
  asesor_id uuid references profiles(id) on delete set null,
  tema text,                           -- tema que eligió
  dolor text,
  notas text,
  dedup_key text,                      -- para evitar duplicados en el import (ig/wsp normalizado)
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
-- índices para que filtrar/ordenar 10k leads sea instantáneo
create index if not exists idx_leads_asesor      on leads(asesor_id);
create index if not exists idx_leads_estado       on leads(estado);
create index if not exists idx_leads_lanzamiento  on leads(lanzamiento_id);
create index if not exists idx_leads_temperatura  on leads(temperatura);
create index if not exists idx_leads_created       on leads(created_at desc);
create unique index if not exists uq_leads_dedup   on leads(lanzamiento_id, dedup_key) where dedup_key is not null;

-- ---------- CONTEXTO DE LEADS (setters + closers) ----------
-- Tabla chica, separada de `leads`: el closer carga un lead que necesita
-- contexto (nombre + lo que tenga) y cualquier setter/closer le suma
-- Situación/Objetivos/Dolores después. Sin agenda ni campos de embudo.
create table if not exists fichas_contexto (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  telefono text,
  asesor_id uuid references profiles(id) on delete set null,
  situacion text, objetivos text, dolor text,
  creado_por uuid references profiles(id) on delete set null,
  lanzamiento_id uuid references lanzamientos(id) on delete set null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists idx_fichas_ctx_lanz   on fichas_contexto(lanzamiento_id);
create index if not exists idx_fichas_ctx_asesor on fichas_contexto(asesor_id);

-- ---------- ASISTENCIA A CLASES ----------
create table if not exists asistencias (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete cascade,
  clase_id uuid references clases(id) on delete cascade,
  asistio boolean default false,
  created_at timestamptz default now(),
  unique (lead_id, clase_id)
);
create index if not exists idx_asist_lead on asistencias(lead_id);

-- ---------- COLA DE SEGUIMIENTOS (trabajo diario del asesor) ----------
create table if not exists seguimientos (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete cascade,
  asesor_id uuid references profiles(id) on delete set null,
  fecha_programada date,
  tipo text,                           -- recordatorio, reactivación, post-clase, etc.
  nota text,
  hecho boolean default false,
  created_at timestamptz default now()
);
create index if not exists idx_seg_asesor_fecha on seguimientos(asesor_id, fecha_programada, hecho);

-- ---------- CLOSER: REPORTES DE LLAMADA ----------
create table if not exists reportes_llamada (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete set null,
  closer_id uuid references profiles(id) on delete set null,
  fecha timestamptz default now(),
  asistio text,                        -- Asistió / No-show / Reprogramó
  resultado text,                      -- Cerró / Seguimiento / No cierre
  fathom_link text,
  programa text,
  forma_cierre text,                   -- Pago único / 2 cuotas / 3 cuotas
  moneda text default 'USD',
  monto_facturado numeric,
  monto_upfront numeric,
  cotizacion numeric,                  -- FX congelada al momento
  billetera text,
  situacion text, dolores text, razones_compra text,
  objecion_principal text, objecion_secundaria text, frases_clave text,
  motivo_no_cierre text, proximo_seguimiento date, estado_seguimiento text,
  total_proyectado numeric, proxima_accion text, feedback text
);
create index if not exists idx_rep_closer on reportes_llamada(closer_id, fecha desc);

-- ---------- COBROS: CUOTAS ----------
create table if not exists cuotas (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete set null,
  programa text,
  moneda text default 'USD',
  monto numeric,
  monto_usd numeric,                   -- convertido y congelado
  vencimiento date,
  billetera text,
  estado text default 'pendiente' check (estado in ('pendiente','cobrado','vencido')),
  origen text,                         -- cierre / upsell / resell / manual
  cobrado_at timestamptz,
  created_at timestamptz default now()
);
create index if not exists idx_cuotas_venc on cuotas(vencimiento);
create index if not exists idx_cuotas_estado on cuotas(estado);

-- ---------- SETTER: KPIs ----------
-- Un solo registro vivo por asesor y lanzamiento (no un historial diario):
-- cada "Guardar" pisa ese mismo registro, así siempre queda el último número.
create table if not exists kpis_diarios (
  id uuid primary key default gen_random_uuid(),
  setter_id uuid references profiles(id) on delete set null,
  lanzamiento_id uuid references lanzamientos(id) on delete set null,
  fecha date not null,
  leads_asignados int default 0, leads_contactados int default 0, leads_sin_responder int default 0,
  leves int default 0, fluidos int default 0, potenciales int default 0, agendas_dia int default 0,
  notas text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (setter_id, lanzamiento_id)
);

-- ---------- MARKETING: PUNTOS DE CONTACTO ----------
create table if not exists puntos_contacto (
  id uuid primary key default gen_random_uuid(),
  tag text, pieza text, plataforma text, fecha date,
  chats_unicos int default 0, leads int default 0, calificados int default 0,
  ventas int default 0, generado numeric default 0,
  created_at timestamptz default now()
);

-- ---------- CONFIG: PROGRAMAS + COTIZACIONES FX ----------
create table if not exists programas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null, precio numeric, moneda text default 'USD', plazo_cuotas int
);
create table if not exists cotizaciones_fx (
  id uuid primary key default gen_random_uuid(),
  moneda text not null, valor numeric not null, fecha date default current_date
);

-- ============================================================
-- RLS (seguridad por rol). Managers/admin ven todo; setters/closers, lo suyo.
-- ============================================================
alter table profiles enable row level security;
alter table leads enable row level security;
alter table seguimientos enable row level security;
alter table reportes_llamada enable row level security;
alter table kpis_diarios enable row level security;
alter table fichas_contexto enable row level security;
-- (las tablas de config/marketing/lanzamientos las dejamos legibles para todos los logueados)
alter table lanzamientos enable row level security;
alter table clases enable row level security;
alter table asistencias enable row level security;
alter table cuotas enable row level security;
alter table puntos_contacto enable row level security;
alter table programas enable row level security;
alter table cotizaciones_fx enable row level security;

-- profiles: todos los logueados los ven (para dropdowns de asignación); cada uno edita el suyo; managers todo.
create policy p_profiles_read on profiles for select using (auth.role() = 'authenticated');
create policy p_profiles_self on profiles for update using (id = auth.uid());
create policy p_profiles_mgr  on profiles for all using (is_manager()) with check (is_manager());

-- leads: managers todo; asesor ve/edita los suyos y los sin asignar (para tomarlos).
create policy p_leads_mgr on leads for all using (is_manager()) with check (is_manager());
create policy p_leads_own on leads for all
  using (asesor_id = auth.uid() or asesor_id is null)
  with check (asesor_id = auth.uid() or asesor_id is null);

-- seguimientos / reportes / kpis: propios, managers todo.
create policy p_seg_mgr on seguimientos for all using (is_manager()) with check (is_manager());
create policy p_seg_own on seguimientos for all using (asesor_id = auth.uid()) with check (asesor_id = auth.uid());
create policy p_rep_mgr on reportes_llamada for all using (is_manager()) with check (is_manager());
create policy p_rep_own on reportes_llamada for all using (closer_id = auth.uid()) with check (closer_id = auth.uid());
create policy p_kpi_mgr on kpis_diarios for all using (is_manager()) with check (is_manager());
create policy p_kpi_own on kpis_diarios for all using (setter_id = auth.uid()) with check (setter_id = auth.uid());

-- fichas_contexto: colaborativo, sin dueño — cualquier logueado crea/lee/edita/borra.
create policy p_fichas_ctx_auth on fichas_contexto for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- config / marketing / lanzamientos: lectura para logueados, escritura managers.
create policy p_read_auth_lanz  on lanzamientos    for select using (auth.role()='authenticated');
create policy p_read_auth_clas  on clases          for select using (auth.role()='authenticated');
create policy p_read_auth_asis  on asistencias     for select using (auth.role()='authenticated');
create policy p_read_auth_cuo   on cuotas          for select using (auth.role()='authenticated');
create policy p_read_auth_pc    on puntos_contacto for select using (auth.role()='authenticated');
create policy p_read_auth_prog  on programas       for select using (auth.role()='authenticated');
create policy p_read_auth_fx    on cotizaciones_fx for select using (auth.role()='authenticated');
create policy p_write_mgr_lanz  on lanzamientos    for all using (is_manager()) with check (is_manager());
create policy p_write_mgr_clas  on clases          for all using (is_manager()) with check (is_manager());
create policy p_write_auth_asis on asistencias     for all using (auth.role()='authenticated') with check (auth.role()='authenticated');
create policy p_write_auth_cuo  on cuotas          for all using (auth.role()='authenticated') with check (auth.role()='authenticated');
create policy p_write_mgr_pc    on puntos_contacto for all using (is_manager()) with check (is_manager());
create policy p_write_mgr_prog  on programas       for all using (is_manager()) with check (is_manager());
create policy p_write_mgr_fx    on cotizaciones_fx for all using (is_manager()) with check (is_manager());

-- Realtime (opcional): que la tabla de leads emita cambios
alter publication supabase_realtime add table leads;

-- ============================================================
-- Trigger: crear profile automáticamente cuando se registra un usuario
-- ============================================================
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, nombre, email) values (new.id, coalesce(new.raw_user_meta_data->>'nombre', new.email), new.email)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();
