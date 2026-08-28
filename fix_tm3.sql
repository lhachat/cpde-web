-- =====================================================================
-- fix_tm3.sql -- correct an illegal TM2/TM3 combination
--
-- FINDING: DEMO opportunity 1 ("First Try") has TM2 = "Yes, us" with
-- TM3 = "N/A". PwinForm's CB_TM2_Change restricts TM3 to the two
-- "We are..." options when TM2 is "Yes, us"; N/A is only legal when
-- TM2 = "No". The row predates the cascade rule or was set programmatically.
--
-- FIX: TM3 -> "We are performing satisfactorily/unknown", the neutral
-- option for an incumbent.
--
-- NOTE ON PWIN: both N/A and WE_SATISFACTORY carry zero score delta in
-- CPwinScoringTables, so the computed Pwin (0.564025) does not change.
-- This corrects the record, not the number -- which is why the bug was
-- invisible until asserted against.
--
--   Get-Content fix_tm3.sql | docker compose exec -T db psql -U cpde -d cpde
-- =====================================================================

BEGIN;

UPDATE pwin_answer w
   SET question_option_id = good.id
  FROM pwin_assessment a
  JOIN pursuit p        ON p.id = a.pursuit_id
  JOIN client c         ON c.id = p.client_id
  JOIN question q       ON q.code = 'TM3'
  JOIN question_option good ON good.question_id = q.id
                           AND good.code = 'WE_SATISFACTORY'
  JOIN question_option bad  ON bad.question_id = q.id
                           AND bad.code = 'NA'
 WHERE w.pwin_assessment_id = a.id
   AND w.question_id        = q.id
   AND w.question_option_id = bad.id
   AND a.is_current
   AND c.code = 'DEMO'
   AND p.external_opportunity_id = '1';

COMMIT;

-- Verify: expect zero rows.
WITH ans AS (
  SELECT a.id, a.pursuit_id,
         max(o.code) FILTER (WHERE q.code='TM2') AS tm2,
         max(o.code) FILTER (WHERE q.code='TM3') AS tm3
    FROM pwin_assessment a
    JOIN pwin_answer w ON w.pwin_assessment_id = a.id
    JOIN question q ON q.id = w.question_id
    JOIN question_option o ON o.id = w.question_option_id
   WHERE a.is_current GROUP BY a.id, a.pursuit_id)
SELECT c.code, p.external_opportunity_id, p.name, ans.tm2, ans.tm3
  FROM ans
  JOIN pursuit p ON p.id = ans.pursuit_id
  JOIN client c  ON c.id = p.client_id
 WHERE ans.tm2 IS NOT NULL AND ans.tm3 IS NOT NULL
   AND NOT (
     (ans.tm2 = 'YES_US'         AND ans.tm3 IN ('WE_SATISFACTORY','WE_ISSUES'))
  OR (ans.tm2 = 'YES_COMPETITOR' AND ans.tm3 IN ('INCUMBENT_SATISFACTORY','INCUMBENT_ISSUES'))
  OR (ans.tm2 = 'NO'             AND ans.tm3 = 'NA'));

-- =====================================================================
-- ALSO FIX THE SOURCE. This corrects the database only. Re-running
-- migrate_workbook.py against the unmodified workbook reintroduces it.
-- Change TM 3 on the "First Try" row of the Pursuits Pwins sheet.
-- =====================================================================
