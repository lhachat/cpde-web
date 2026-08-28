-- =====================================================================
-- fix_calendar_year.sql -- one-off backfill
--
-- pursuit_year_projection.calendar_year was never populated: the migration
-- wrote year_offset only. Every year-based rollup therefore returned
-- nothing, silently -- no error, just an empty dashboard.
--
-- year_offset 1 == the planning year, so calendar_year = plan_start + n - 1.
-- The planning year is taken from each client's earliest plan_year row,
-- so this is correct per tenant rather than assuming 2026 everywhere.
--
-- The migration now does this on load; this file fixes data already in
-- the database. Safe to re-run.
--
--   Get-Content fix_calendar_year.sql | docker compose exec -T db psql -U cpde -d cpde
-- =====================================================================

BEGIN;

WITH base AS (
    SELECT o.client_id, min(y.calendar_year) AS plan_start
      FROM plan_year y
      JOIN org_node o ON o.id = y.org_node_id
     GROUP BY o.client_id
)
UPDATE pursuit_year_projection yp
   SET calendar_year = b.plan_start + yp.year_offset - 1
  FROM base b
 WHERE yp.client_id = b.client_id
   AND yp.calendar_year IS DISTINCT FROM b.plan_start + yp.year_offset - 1;

COMMIT;

SELECT c.code,
       count(*)                        AS rows,
       count(yp.calendar_year)         AS dated,
       min(yp.calendar_year)           AS first_year,
       max(yp.calendar_year)           AS last_year
  FROM pursuit_year_projection yp
  JOIN client c ON c.id = yp.client_id
 GROUP BY c.code ORDER BY c.code;
