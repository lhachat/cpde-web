# Run every suite. Non-zero exit if any fail.
# Usage:  .\run_tests.ps1
$ErrorActionPreference = "Continue"

$ADMIN = "postgresql://cpde:localdev@localhost:5433/cpde"
$APP   = "postgresql://cpde_api:localdev_api@localhost:5433/cpde"
$fail  = 0

Write-Host "`n########## TENANT ISOLATION ##########" -ForegroundColor Cyan
python test_isolation.py --admin-dsn $ADMIN --app-dsn $APP
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host "`n########## SCOPE FILTERING ##########" -ForegroundColor Cyan
python test_scope.py --admin-dsn $ADMIN --app-dsn $APP
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host "`n########## DATA INTEGRITY ##########" -ForegroundColor Cyan
python test_integrity.py --dsn $ADMIN
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host "`n########## MARKET SYNC ##########" -ForegroundColor Cyan
python test_market_sync.py --admin-dsn $ADMIN
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host "`n########## RECALC RESPONSE HANDLING ##########" -ForegroundColor Cyan
python test_recalc_response_handling.py --admin-dsn $ADMIN
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host "`n########## SCORING TABLE MIGRATION ##########" -ForegroundColor Cyan
python test_scoring_migration.py --admin-dsn $ADMIN
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host "`n########## FEE/COMPETITOR MIGRATION ##########" -ForegroundColor Cyan
python test_fee_competitor_migration.py --admin-dsn $ADMIN
if ($LASTEXITCODE -ne 0) { $fail = 1 }

# Needs the API running on :8001 -- section 3 confirms GET /api/reference
# actually exposes the questionnaire live, not just that scoring.py's
# own in-process logic works. Skipped, not failed, if the API is down.
Write-Host "`n########## QUESTIONNAIRE MIGRATION ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    python test_questionnaire_migration.py --admin-dsn $ADMIN
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

# Needs the API running on :8001. Skipped if it is not up, because a
# skipped suite you know about beats a red run you learn to ignore.
Write-Host "`n########## API SECURITY ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    python test_api_security.py --base http://localhost:8001 --admin-dsn $ADMIN
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

# Needs the API running on :8001 -- the real PATCH endpoint, not just the
# schema, is what proves the Owner/POC scope check is actually enforced.
Write-Host "`n########## PURSUIT OWNER/POC ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    python test_pursuit_owner.py --base http://localhost:8001 --admin-dsn $ADMIN
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

# Needs the API running on :8001 -- the real PATCH endpoint is what
# proves the depends-on picker's scope/self/cycle checks are actually
# enforced, not just representable in the schema.
Write-Host "`n########## PURSUIT DEPENDS-ON ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    python test_pursuit_dependency.py --base http://localhost:8001 --admin-dsn $ADMIN
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

Write-Host "`n########## STAFFING ESCALATION ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    python test_staffing_escalation.py --base http://localhost:8001 --admin-dsn $ADMIN
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

# Needs BOTH the API and a live AWS session -- scoring.get_questionnaire()
# needs the real engine spec loaded to validate an answer/cascade, same
# reasoning as ENGINE CLIENT/TM1A+TM1B->TM2 below. Skipped, not failed,
# if either is unavailable.
Write-Host "`n########## QUESTIONNAIRE ANSWER SAVE PATH ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    docker exec cpde-api python -c "import boto3; boto3.client('sts').get_caller_identity()" 2>$null
    if ($LASTEXITCODE -eq 0) {
        python test_questionnaire_answers.py --base http://localhost:8001 --admin-dsn $ADMIN
        if ($LASTEXITCODE -ne 0) { $fail = 1 }
    } else {
        Write-Host "SKIPPED - no live AWS session in the api container; run .\refresh-aws-creds.ps1 first" -ForegroundColor Yellow
    }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

# Needs BOTH the API and a live AWS session -- submitting a Black Hat
# assessment calls the real resolve_fee() against whatever the running
# API process has cached from the live engine, same reasoning as
# ENGINE CLIENT below. Skipped, not failed, if either is unavailable.
Write-Host "`n########## BH/PTW PHASE CHANGE ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    docker exec cpde-api python -c "import boto3; boto3.client('sts').get_caller_identity()" 2>$null
    if ($LASTEXITCODE -eq 0) {
        python test_bhptw_phase_change.py --base http://localhost:8001 --admin-dsn $ADMIN
        if ($LASTEXITCODE -ne 0) { $fail = 1 }
    } else {
        Write-Host "SKIPPED - no live AWS session in the api container; run .\refresh-aws-creds.ps1 first" -ForegroundColor Yellow
    }
} catch {
    Write-Host "SKIPPED - API not reachable on :8001" -ForegroundColor Yellow
}

# Needs a live, correctly-scoped AWS session (run .\refresh-aws-creds.ps1
# first) reaching the API container -- that is where real credentials
# actually live (via .env -> docker-compose interpolation), not
# necessarily this host shell. Skipped, not failed, if no session is
# present -- most days nobody touches SSM resolution, and a hard
# failure here would train everyone to ignore this suite.
Write-Host "`n########## ENGINE CLIENT (real AWS/SSM) ##########" -ForegroundColor Cyan
docker exec cpde-api python -c "import boto3; boto3.client('sts').get_caller_identity()" 2>$null
if ($LASTEXITCODE -eq 0) {
    docker cp test_engine_client.py cpde-api:/tmp/test_engine_client.py | Out-Null
    docker exec cpde-api python /tmp/test_engine_client.py
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    docker exec cpde-api rm -f /tmp/test_engine_client.py | Out-Null
} else {
    Write-Host "SKIPPED - no live AWS session in the api container; run .\refresh-aws-creds.ps1 first" -ForegroundColor Yellow
}

# Same reasoning as ENGINE CLIENT above -- needs a real fetch against
# the live engine to confirm the tm1a_tm1b_to_tm2 cascade fix (v0.33)
# actually landed, not a stale cached v0.32 payload. Run inside the API
# container, where the real credentials live.
Write-Host "`n########## TM1A+TM1B->TM2 CASCADE RE-VERIFICATION ##########" -ForegroundColor Cyan
docker exec cpde-api python -c "import boto3; boto3.client('sts').get_caller_identity()" 2>$null
if ($LASTEXITCODE -eq 0) {
    docker cp test_tm1a_tm1b_tm2_cascade.py cpde-api:/tmp/test_tm1a_tm1b_tm2_cascade.py | Out-Null
    docker exec cpde-api python /tmp/test_tm1a_tm1b_tm2_cascade.py --admin-dsn "postgresql://cpde:localdev@cpde-db:5432/cpde"
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
    docker exec cpde-api rm -f /tmp/test_tm1a_tm1b_tm2_cascade.py | Out-Null
} else {
    Write-Host "SKIPPED - no live AWS session in the api container; run .\refresh-aws-creds.ps1 first" -ForegroundColor Yellow
}

if ($fail) {
    Write-Host "`nSUITES FAILED" -ForegroundColor Red
} else {
    Write-Host "`nALL SUITES PASSED" -ForegroundColor Green
}
exit $fail
