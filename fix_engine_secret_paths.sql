-- Project: cpde-web
-- =====================================================================
-- fix_engine_secret_paths.sql -- point engine_secret_ref at key-value
--
-- client.engine_secret_ref currently holds the OLD flat SSM paths
-- (/cda/clients/{client}/api-key), deleted in the per-product API key
-- scoping cutover. Confirmed live against the real infrastructure: the
-- USABLE secret is key-value (SecureString, KMS-encrypted) under the new
-- /products/cpde-core/ path -- key-id is a plain-String Gateway
-- identifier, never usable as x-api-key. Pointing at the wrong one would
-- fail every /v1/run call with no clear reason why.
-- =====================================================================

BEGIN;

UPDATE client
   SET engine_secret_ref = '/cda/clients/collins/products/cpde-core/key-value'
 WHERE code = 'DEMO';

UPDATE client
   SET engine_secret_ref = '/cda/clients/cda-internal/products/cpde-core/key-value'
 WHERE code = 'AERO';

COMMIT;

-- Verify:
SELECT code, engine_client_code, engine_secret_ref FROM client ORDER BY code;
-- Both engine_secret_ref values should end in /products/cpde-core/key-value,
-- not the old flat /api-key shape.
