-- ============================================================
-- MIGRACIÓN · lanzamiento_id en Cuotas y KPIs diarios (NAVE CRM)
-- Sin esto, "Cobros del lanzamiento" y "Estado del equipo" en el Panel
-- general siempre mostraban el acumulado de TODOS los lanzamientos
-- juntos, sin importar cuál esté activo.
-- Pegar TODO en Supabase → SQL Editor → Run. Es idempotente (se puede
-- correr más de una vez).
-- ============================================================

-- ---------- CUOTAS ----------
alter table cuotas add column if not exists lanzamiento_id uuid references lanzamientos(id) on delete set null;
create index if not exists idx_cuotas_lanzamiento on cuotas(lanzamiento_id);

-- ---------- KPIS DIARIOS ----------
alter table kpis_diarios add column if not exists lanzamiento_id uuid references lanzamientos(id) on delete set null;
create index if not exists idx_kpis_lanzamiento on kpis_diarios(lanzamiento_id);

-- El índice único viejo era (setter_id, fecha) — un setter no podía cargar
-- dos KPIs el mismo día ni siquiera en lanzamientos distintos. Lo cambiamos
-- para que sea por lanzamiento, así cada ciclo arranca su propia planilla.
alter table kpis_diarios drop constraint if exists kpis_diarios_setter_id_fecha_key;
create unique index if not exists uq_kpis_setter_fecha_lanz on kpis_diarios(setter_id, fecha, lanzamiento_id);

-- ---------- DATOS VIEJOS ----------
-- Las filas de cuotas y kpis_diarios cargadas ANTES de esta migración
-- quedan con lanzamiento_id en null. Es a propósito: así no se mezclan
-- con el lanzamiento activo de hoy — la app solo cuenta lo que tiene el
-- lanzamiento_id del lanzamiento seleccionado. No se borra nada, sigue
-- ahí por si hace falta auditarlo directo en Supabase.
--
-- Si en algún momento querés que esas filas viejas queden asociadas a un
-- lanzamiento puntual (por ejemplo el "1.0"), corré esto reemplazando el
-- uuid por el id real de ese lanzamiento (lo ves en Comisiones → Lanzamientos):
--
--   update cuotas set lanzamiento_id = '<uuid-del-1.0>'
--     where lanzamiento_id is null
--       and venta_id in (select id from ventas where lanzamiento_id = '<uuid-del-1.0>');
--
--   update kpis_diarios set lanzamiento_id = '<uuid-del-1.0>'
--     where lanzamiento_id is null
--       and fecha < '2026-09-16'; -- ajustar a la fecha real de corte del 1.0

-- ============================================================
-- LISTO. La app ya filtra Cobros y Estado del equipo por el lanzamiento activo.
-- ============================================================
