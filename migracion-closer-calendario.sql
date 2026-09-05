-- ============================================================
-- Calendario para closers: agregar closer_id a "seguimientos"
-- Pegar TODO en Supabase → SQL Editor → Run. Idempotente, no borra nada.
--
-- Hoy "seguimientos.asesor_id" es siempre el setter dueño del lead. Para que
-- el closer asignado por el round robin de Calendly también vea la llamada
-- en SU propio calendario, agregamos una columna separada para el closer.
-- ============================================================

alter table seguimientos add column if not exists closer_id uuid references profiles(id) on delete set null;
