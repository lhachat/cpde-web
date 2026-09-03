-- Project: cpde-web
-- =====================================================================
-- fix_collins_client_code.sql -- correct the engine identity mismatch
--
-- client.engine_client_code for DEMO was set to 'collins'. The real,
-- provisioned SSM namespace (confirmed live, aws ssm get-parameters-by-
-- path) is 'collins-aerospace' -- the name used when the Salesforce
-- per-product API key work created this client's SSM tree. Nothing was
-- ever broken or missing; the two pieces of work simply named the same
-- real client differently, and cpde-web never noticed because the old
-- resolved path (engine_secret_ref) worked fine right up until it was
-- pointed at the new /products/cpde-core/ shape two rounds ago -- at
-- which point the mismatch in engine_client_code became load-bearing.
-- =====================================================================

BEGIN;

UPDATE client
   SET engine_client_code = 'collins-aerospace',
       engine_secret_ref  = '/cda/clients/collins-aerospace/products/cpde-core/key-value'
 WHERE code = 'DEMO';

COMMIT;

-- Verify:
SELECT code, engine_client_code, engine_secret_ref FROM client ORDER BY code;
-- DEMO's engine_client_code should now read 'collins-aerospace', and
-- engine_secret_ref should match the real, confirmed SSM path exactly.
