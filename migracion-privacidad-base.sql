-- ============================================================
-- Privacidad de "Mi base" (leads importados por CSV, fuente = 'base propia')
-- Pegar TODO en Supabase → SQL Editor → Run. Idempotente.
--
-- Qué hace: reemplaza la política de SELECT de "leads" para que los leads
-- con fuente='base propia' SOLO los pueda ver el asesor dueño (asesor_id)
-- y los manager/admin. El resto de los leads (embudo normal, agendas, etc.)
-- sigue visible para todo el equipo autenticado, exactamente igual que antes.
-- ============================================================

drop policy if exists "leads_select_equipo" on leads;
create policy "leads_select_equipo" on leads for select
using (
  fuente is distinct from 'base propia'
  or asesor_id = auth.uid()
  or exists (select 1 from profiles where id = auth.uid() and rol in ('manager','admin'))
);
