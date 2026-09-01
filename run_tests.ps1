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

if ($fail) {
    Write-Host "`nSUITES FAILED" -ForegroundColor Red
} else {
    Write-Host "`nALL SUITES PASSED" -ForegroundColor Green
}
exit $fail
