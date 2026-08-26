-- =====================================================================
-- set_engine_identity.sql -- Per-tenant engine credentials (DATA)
--
-- Run AFTER migrate_workbook.py has loaded both tenants.
-- Do NOT put this in ddl/ -- it needs client rows that do not exist at
-- database init time.
--
--   Get-Content set_engine_identity.sql | docker compose exec -T db psql -U cpde -d cpde
--
-- Idempotent. Adjust the SSM paths to match the real ones.
-- =====================================================================

BEGIN;

-- DEMO: 36 pursuits, Collins markets (BMC2A, OCS - General, OCS - Waveforms)
UPDATE client SET
    engine_client_code = 'collins',
    engine_secret_ref  = '/cda/clients/collins/api-key'
 WHERE code = 'DEMO';

-- AERO: 150 pursuits, CDA internal markets (GSS, ACP, MSN, SUS, SPC, TRN)
UPDATE client SET
    engine_client_code = 'cda-internal',
    engine_secret_ref  = '/cda/clients/cda-internal/api-key'
 WHERE code = 'AERO';

COMMIT;

SELECT code, name, engine_client_code, engine_secret_ref FROM client ORDER BY code;

-- =====================================================================
-- VALIDATION WORTH BUILDING INTO THE APP
--
-- Every market code in the database must exist in that client's engine
-- config, or the differential lookup silently falls back. SQL cannot check
-- this -- the engine config lives in SSM. Do it at startup or on deploy:
--
--   for each client:
--     db_codes     = SELECT code FROM market WHERE client_id = ...
--     engine_codes = GET /v1/markets  (using that client's key)
--     assert db_codes is a subset of engine_codes
--
-- This is the check that catches a market defined client-side that the
-- engine has no differential for.
-- =====================================================================
