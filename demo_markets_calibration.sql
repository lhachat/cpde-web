-- CDA-SIDE ONLY. Do NOT load into the client-facing database.
-- Price differentials are engine IP (decision 2b).
-- market_calibration is keyed (client_code, market_code).

INSERT INTO market_calibration (client_code,market_code,price_differential,effective_from,calibration_version)
VALUES ('DEMO','GSS',-0.041,DATE '2026-01-01','demo-1');
INSERT INTO market_calibration (client_code,market_code,price_differential,effective_from,calibration_version)
VALUES ('DEMO','ACP',0.0007,DATE '2026-01-01','demo-1');
INSERT INTO market_calibration (client_code,market_code,price_differential,effective_from,calibration_version)
VALUES ('DEMO','MSN',0.0,DATE '2026-01-01','demo-1');
INSERT INTO market_calibration (client_code,market_code,price_differential,effective_from,calibration_version)
VALUES ('DEMO','SUS',-0.018,DATE '2026-01-01','demo-1');
INSERT INTO market_calibration (client_code,market_code,price_differential,effective_from,calibration_version)
VALUES ('DEMO','SPC',0.025,DATE '2026-01-01','demo-1');
INSERT INTO market_calibration (client_code,market_code,price_differential,effective_from,calibration_version)
VALUES ('DEMO','TRN',0.027,DATE '2026-01-01','demo-1');
