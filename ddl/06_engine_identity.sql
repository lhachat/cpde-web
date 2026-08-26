-- =====================================================================
-- 06_engine_identity.sql -- Map a tenant to its engine credential (SCHEMA)
--
-- Goes in ddl/ so it survives `docker compose down -v`.
-- The per-client VALUES live in set_engine_identity.sql, which runs after
-- migrate_workbook.py has created the client rows.
--
-- WHY: the workbook carried its API key in EngineConfig, so it always knew
-- which client it was. A shared web app serving several tenants does not.
-- The backend must resolve client_id -> engine credential before calling
-- /v1/pwin, because the key is what tells the engine which market
-- differentials to apply.
--
-- WHAT IS STORED: a REFERENCE ONLY -- an SSM path or Secrets Manager ARN.
-- Never the key. The backend resolves the secret at call time using its own
-- IAM permissions. The client-facing database never holds a credential.
-- =====================================================================

ALTER TABLE client
    ADD COLUMN IF NOT EXISTS engine_client_code TEXT,
    ADD COLUMN IF NOT EXISTS engine_secret_ref  TEXT,
    ADD COLUMN IF NOT EXISTS engine_base_url    TEXT
        DEFAULT 'https://api.cda-us.com';

COMMENT ON COLUMN client.engine_client_code IS
    'Engine-side client identity -- the {client} segment in '
    '/cda/clients/{client}/config. Determines which market differentials '
    'the engine applies. NOT the same as client.code, which is ours.';

COMMENT ON COLUMN client.engine_secret_ref IS
    'Pointer to the API key -- SSM path or Secrets Manager ARN. NEVER the '
    'key itself. Resolved by the application at call time via IAM.';
