-- ============================================================
-- MIGRACIÓN · Contexto de leads (setters + closers)
-- Tabla chica y separada de `leads`: un closer carga un lead que necesita
-- contexto (nombre + lo que tenga a mano) y cualquier setter/closer entra
-- después y le suma Situación/Objetivos/Dolores. No depende de agendas ni
-- del embudo de marketing (fuente/temperatura/estado) — por eso es tabla
-- propia y no una vista de `leads`.
-- Pegar TODO en Supabase → SQL Editor → Run. Es idempotente.
-- ============================================================

create table if not exists fichas_contexto (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  telefono text,
  asesor_id uuid references profiles(id) on delete set null,   -- setter que trabajó el lead, si se sabe
  situacion text, objetivos text, dolor text,                  -- el contexto en sí
  creado_por uuid references profiles(id) on delete set null,
  lanzamiento_id uuid references lanzamientos(id) on delete set null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists idx_fichas_ctx_lanz   on fichas_contexto(lanzamiento_id);
create index if not exists idx_fichas_ctx_asesor on fichas_contexto(asesor_id);

-- Colaborativo por diseño: cualquier setter/closer/manager logueado puede
-- crear, leer, editar o borrar — a diferencia de `leads`/`kpis_diarios`
-- (que son "lo mío"), acá el punto es que el closer carga y el setter (u
-- otro closer) completa, sin dueño único.
alter table fichas_contexto enable row level security;
drop policy if exists "fichas_ctx_all_auth" on fichas_contexto;
create policy "fichas_ctx_all_auth" on fichas_contexto for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
