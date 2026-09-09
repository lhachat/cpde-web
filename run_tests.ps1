# Run every suite, and say honestly what actually ran.
#
# Usage:  .\run_tests.ps1 [-AllowSkips]
#
# Exit codes -- three states, not two:
#   0  every suite RAN and every assertion passed (a genuinely clean run)
#   2  everything that ran passed, but at least one suite was SKIPPED
#      (no API, no AWS session, no playwright) -- NOT a clean run. A
#      script or CI job checking only "was it zero?" cannot mistake this
#      for a clean one. Pass -AllowSkips to map this to 0 when skips are
#      expected (a machine with no AWS session on purpose); the banner
#      still says WITH SKIPS either way.
#   1  at least one assertion failed, or a suite crashed / printed no
#      summary line
#
# Found by the security audit: this harness used to print an unqualified
# "ALL SUITES PASSED" over silently skipped suites (yellow text only,
# never counted, never in the exit code). With no AWS session, SEVEN
# suites skipped under a green banner. Every per-suite "N passed, M
# failed" line is now parsed and machine-summed here -- no hand-assembled
# totals -- and a suite that runs but prints no such line is a failure,
# not a pass.
param([switch]$AllowSkips)
$ErrorActionPreference = "Continue"

$ADMIN = "postgresql://cpde:localdev@localhost:5433/cpde"
$APP   = "postgresql://cpde_api:localdev_api@localhost:5433/cpde"
$BASE  = "http://localhost:8001"

# Assertion count per suite AS OF THE LAST FULL RUN. Used for exactly one
# thing: saying how many assertions a SKIPPED suite would have run, so a
# skip-heavy run states its real gap in numbers. Never used to decide
# pass/fail. Every suite that actually runs is compared against this
# table and a mismatch prints a loud "table stale" warning -- so it cannot
# silently rot. Update it when a suite grows.
$Expected = [ordered]@{
    'TENANT ISOLATION'                          = 29
    'SCOPE FILTERING'                           = 14
    'DATA INTEGRITY'                            = 44
    'MARKET SYNC'                               = 19
    'RECALC RESPONSE HANDLING'                  = 3
    'SCORING TABLE MIGRATION'                   = 10
    'FEE/COMPETITOR MIGRATION'                  = 8
    'QUESTIONNAIRE MIGRATION'                   = 11
    'API SECURITY'                              = 127
    'PURSUIT OWNER/POC'                         = 14
    'PURSUIT DEPENDS-ON'                        = 18
    'STAFFING ESCALATION'                       = 14
    'QUESTIONNAIRE ANSWER SAVE PATH'            = 40
    'LPTA EVAL_TYPE DERIVATION'                 = 8
    'BLENDED_PWIN (dependency blend)'           = 25
    'SOLE-SOURCE/LPTA DEPENDENCY RESTRICTION'   = 6
    'CANCELLED PREDECESSOR AUTO-CLEAR'          = 19
    'XSS ESCAPING + CSP (Playwright)'           = 28
    'REVERT TO PRE-BH (fresh recalculation)'    = 13
    'BH/PTW PHASE CHANGE'                       = 11
    'ENGINE CLIENT (real AWS/SSM)'              = 10
    'TM1A+TM1B->TM2 CASCADE RE-VERIFICATION'    = 4
}

$Results = New-Object System.Collections.ArrayList

# Summary/banner lines go to the OUTPUT stream (Write-Output), not
# Write-Host: a plain "run_tests.ps1 > run.log" redirect (what a CI job
# or a script checking the result does) does not capture Write-Host, and
# these are exactly the lines such a reader needs.
function Say { param([string]$Text) Write-Output $Text }


function Invoke-Suite {
    param([string]$Name, [scriptblock]$Cmd)
    Write-Host "`n########## $Name ##########" -ForegroundColor Cyan
    # stdout is captured AND echoed (the per-suite "N passed, M failed" line
    # is what gets parsed); stderr flows straight to the console.
    $out = & $Cmd | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host $_ }
    $m = $out | Select-String -Pattern '^\s*(\d+) passed, (\d+) failed' | Select-Object -Last 1
    $passed = 0; $failed = 0; $status = 'pass'; $note = ''
    if ($m) {
        $passed = [int]$m.Matches[0].Groups[1].Value
        $failed = [int]$m.Matches[0].Groups[2].Value
        if ($failed -gt 0 -or $code -ne 0) { $status = 'fail'; $note = "exit $code" }
    } else {
        $status = 'fail'; $note = "no 'N passed, M failed' summary line (crashed? exit $code)"
    }
    if ($status -eq 'pass' -and $Expected.Contains($Name) -and $Expected[$Name] -ne $passed) {
        $note = "count changed: table says $($Expected[$Name]) -- update `$Expected in run_tests.ps1"
        Write-Host "  NOTE  $note" -ForegroundColor Yellow
    }
    [void]$Results.Add([pscustomobject]@{Name=$Name; Status=$status; Passed=$passed; Failed=$failed; Note=$note})
}

function Skip-Suite {
    param([string]$Name, [string]$Reason)
    Write-Host "`n########## $Name ##########" -ForegroundColor Cyan
    Write-Host "SKIPPED - $Reason" -ForegroundColor Yellow
    $exp = if ($Expected.Contains($Name)) { $Expected[$Name] } else { $null }
    [void]$Results.Add([pscustomobject]@{Name=$Name; Status='skip'; Passed=0; Failed=0; Note=$Reason; Expected=$exp})
}

# ---- environment gates, evaluated ONCE and reported up front ----------
$ApiUp = $false
try { Invoke-WebRequest -Uri "$BASE/health" -TimeoutSec 3 -UseBasicParsing | Out-Null; $ApiUp = $true } catch {}
docker exec cpde-api python -c "import boto3; boto3.client('sts').get_caller_identity()" 2>$null | Out-Null
$AwsLive = ($LASTEXITCODE -eq 0)
$PlaywrightPresent = Test-Path "node_modules\playwright"
$NoApi = "API not reachable on :8001"
$NoAws = "no live AWS session in the api container; run .\refresh-aws-creds.ps1 first"
$NoPw  = "node_modules/playwright missing; run npm install first"
Say "Environment: API=$(if($ApiUp){'up'}else{'DOWN'})  AWS session=$(if($AwsLive){'live'}else{'NONE'})  playwright=$(if($PlaywrightPresent){'present'}else{'MISSING'})"

# ---- suites ------------------------------------------------------------
Invoke-Suite 'TENANT ISOLATION'         { python test_isolation.py --admin-dsn $ADMIN --app-dsn $APP }
Invoke-Suite 'SCOPE FILTERING'          { python test_scope.py --admin-dsn $ADMIN --app-dsn $APP }
Invoke-Suite 'DATA INTEGRITY'           { python test_integrity.py --dsn $ADMIN }
Invoke-Suite 'MARKET SYNC'              { python test_market_sync.py --admin-dsn $ADMIN }
Invoke-Suite 'RECALC RESPONSE HANDLING' { python test_recalc_response_handling.py --admin-dsn $ADMIN }
Invoke-Suite 'SCORING TABLE MIGRATION'  { python test_scoring_migration.py --admin-dsn $ADMIN }
Invoke-Suite 'FEE/COMPETITOR MIGRATION' { python test_fee_competitor_migration.py --admin-dsn $ADMIN }

# Need the API on :8001 -- these exercise real endpoints, not just schema.
$ApiSuites = @(
    @{N='API SECURITY';                            C={ python test_api_security.py --base $BASE --admin-dsn $ADMIN }},
    @{N='PURSUIT OWNER/POC';                       C={ python test_pursuit_owner.py --base $BASE --admin-dsn $ADMIN }},
    @{N='PURSUIT DEPENDS-ON';                      C={ python test_pursuit_dependency.py --base $BASE --admin-dsn $ADMIN }},
    @{N='STAFFING ESCALATION';                     C={ python test_staffing_escalation.py --base $BASE --admin-dsn $ADMIN }}
)
foreach ($s in $ApiSuites) { if ($ApiUp) { Invoke-Suite $s.N $s.C } else { Skip-Suite $s.N $NoApi } }

# Need the API AND a live AWS session -- real recalculations call the
# real engine; answer/cascade validation needs the live engine spec.
# QUESTIONNAIRE MIGRATION moved here (was API-only): its own section 3
# asserts GET /api/reference's questionnaire key is actually non-null,
# which depends on the API CONTAINER's own AWS session having loaded the
# live engine spec at startup -- not merely on the API being reachable.
# Previously mis-gated on API-only, that assertion silently ran fewer
# checks (9 vs 10) whenever the container had no AWS session, instead of
# either failing or the whole suite being skipped -- found by the
# harness's own drift detector. Now: skipped cleanly (like every sibling
# suite here) when there's no session, and asserted for real (now fails
# loudly, not silently) whenever this suite does run.
$AwsApiSuites = @(
    @{N='QUESTIONNAIRE MIGRATION';                 C={ python test_questionnaire_migration.py --admin-dsn $ADMIN }},
    @{N='QUESTIONNAIRE ANSWER SAVE PATH';          C={ python test_questionnaire_answers.py --base $BASE --admin-dsn $ADMIN }},
    @{N='LPTA EVAL_TYPE DERIVATION';               C={ python test_lpta_eval_type.py --base $BASE --admin-dsn $ADMIN }},
    @{N='BLENDED_PWIN (dependency blend)';         C={ python test_blended_pwin.py --base $BASE --admin-dsn $ADMIN }},
    @{N='CANCELLED PREDECESSOR AUTO-CLEAR';        C={ python test_cancelled_predecessor.py --base $BASE --admin-dsn $ADMIN }}
)
foreach ($s in $AwsApiSuites) {
    if (-not $ApiUp) { Skip-Suite $s.N $NoApi } elseif (-not $AwsLive) { Skip-Suite $s.N $NoAws } else { Invoke-Suite $s.N $s.C }
}

if ($ApiUp) { Invoke-Suite 'SOLE-SOURCE/LPTA DEPENDENCY RESTRICTION' { python test_dependency_restrictions.py --base $BASE --admin-dsn $ADMIN } }
else        { Skip-Suite   'SOLE-SOURCE/LPTA DEPENDENCY RESTRICTION' $NoApi }

# Drives the real UI in headless Chromium: plants the audit's exact XSS
# payload via the real PATCH endpoint, asserts it renders inert in every
# view, and that the CSP actually blocks injected inline script.
if (-not $ApiUp)                { Skip-Suite 'XSS ESCAPING + CSP (Playwright)' $NoApi }
elseif (-not $PlaywrightPresent) { Skip-Suite 'XSS ESCAPING + CSP (Playwright)' $NoPw }
else { Invoke-Suite 'XSS ESCAPING + CSP (Playwright)' { node test_xss_escaping.js --base $BASE } }

$AwsApiSuites2 = @(
    @{N='REVERT TO PRE-BH (fresh recalculation)';  C={ python test_revert_to_pre_bh.py --base $BASE --admin-dsn $ADMIN }},
    @{N='BH/PTW PHASE CHANGE';                     C={ python test_bhptw_phase_change.py --base $BASE --admin-dsn $ADMIN }}
)
foreach ($s in $AwsApiSuites2) {
    if (-not $ApiUp) { Skip-Suite $s.N $NoApi } elseif (-not $AwsLive) { Skip-Suite $s.N $NoAws } else { Invoke-Suite $s.N $s.C }
}

# Run INSIDE the api container, where the real credentials live (via
# .env -> docker-compose interpolation), not necessarily this host shell.
if ($AwsLive) {
    Invoke-Suite 'ENGINE CLIENT (real AWS/SSM)' {
        docker cp test_engine_client.py cpde-api:/tmp/test_engine_client.py | Out-Null
        docker exec cpde-api python /tmp/test_engine_client.py
        $rc = $LASTEXITCODE
        docker exec cpde-api rm -f /tmp/test_engine_client.py | Out-Null
        $global:LASTEXITCODE = $rc
    }
    Invoke-Suite 'TM1A+TM1B->TM2 CASCADE RE-VERIFICATION' {
        docker cp test_tm1a_tm1b_tm2_cascade.py cpde-api:/tmp/test_tm1a_tm1b_tm2_cascade.py | Out-Null
        docker exec cpde-api python /tmp/test_tm1a_tm1b_tm2_cascade.py --admin-dsn "postgresql://cpde:localdev@cpde-db:5432/cpde"
        $rc = $LASTEXITCODE
        docker exec cpde-api rm -f /tmp/test_tm1a_tm1b_tm2_cascade.py | Out-Null
        $global:LASTEXITCODE = $rc
    }
} else {
    Skip-Suite 'ENGINE CLIENT (real AWS/SSM)' $NoAws
    Skip-Suite 'TM1A+TM1B->TM2 CASCADE RE-VERIFICATION' $NoAws
}

# ---- summary: machine-summed, three states ------------------------------
$ran     = @($Results | Where-Object { $_.Status -ne 'skip' })
$skipped = @($Results | Where-Object { $_.Status -eq 'skip' })
$failed  = @($Results | Where-Object { $_.Status -eq 'fail' })
$totalPassed = ($ran | Measure-Object -Property Passed -Sum).Sum
$totalFailed = ($ran | Measure-Object -Property Failed -Sum).Sum
$skippedAssertions = ($skipped | Where-Object { $_.Expected } | Measure-Object -Property Expected -Sum).Sum
if (-not $totalPassed) { $totalPassed = 0 }; if (-not $totalFailed) { $totalFailed = 0 }; if (-not $skippedAssertions) { $skippedAssertions = 0 }

Say "`n$('=' * 70)"
Say ("{0,-46} {1,-6} {2,7} {3,7}" -f 'Suite', 'Result', 'Passed', 'Failed')
foreach ($r in $Results) {
    $line = "{0,-46} {1,-6} {2,7} {3,7}" -f $r.Name, $r.Status.ToUpper(), $r.Passed, $r.Failed
    if ($r.Status -eq 'skip') { $line = "{0,-46} {1,-6} {2,7} {3,7}   ({4} assertions not run: {5})" -f $r.Name, 'SKIP', '-', '-', ($(if($r.Expected){$r.Expected}else{'?'})), $r.Note }
    elseif ($r.Note) { $line += "   $($r.Note)" }
    Say $line
}
Say ('-' * 70)
Say ("Ran {0} of {1} suites: {2} assertions passed, {3} failed (machine-summed from each suite's own summary line)." -f $ran.Count, $Results.Count, $totalPassed, $totalFailed)

if ($failed.Count -gt 0) {
    Say "`nSUITES FAILED: $($failed.Count) suite(s) -- $(($failed | ForEach-Object { $_.Name }) -join '; ')"
    if ($skipped.Count -gt 0) { Say "(and $($skipped.Count) suite(s) skipped, ~$skippedAssertions assertions never ran)" }
    exit 1
}
if ($skipped.Count -gt 0) {
    Say "`nPASSED WITH SKIPS -- NOT a clean run."
    Say ("Everything that ran passed, but {0} of {1} suites did NOT run (~{2} assertions never executed):" -f $skipped.Count, $Results.Count, $skippedAssertions)
    foreach ($s in $skipped) { Say ("  - {0}  [{1} assertions]  {2}" -f $s.Name, ($(if($s.Expected){$s.Expected}else{'?'})), $s.Note) }
    if ($AllowSkips) { Say "(-AllowSkips: exiting 0 anyway)"; exit 0 }
    exit 2
}
Say "`nALL SUITES PASSED -- every one of the $($Results.Count) suites ran; $totalPassed assertions, machine-summed."
exit 0
