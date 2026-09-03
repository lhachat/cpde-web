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

Write-Host "`n########## STAFFING ESCALATION ##########" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://localhost:8001/health" -TimeoutSec 3 -UseBasicParsing | Out-Null
    python test_staffing_escalation.py --base http://localhost:8001 --admin-dsn $ADMIN
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
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

if ($fail) {
    Write-Host "`nSUITES FAILED" -ForegroundColor Red
} else {
    Write-Host "`nALL SUITES PASSED" -ForegroundColor Green
}
exit $fail
