# scheduled-refresh-wrapper.ps1 -- runs refresh-aws-creds.ps1 unattended
# (from the Scheduled Task registered by install-refresh-task.ps1) and
# logs the outcome, since nothing is watching an interactive console
# when this fires.
#
# NOT meant to be run by hand -- just run .\refresh-aws-creds.ps1
# directly for that; this wrapper only exists to make an unattended
# failure (most likely: the base SSO session itself has expired, which
# refresh-aws-creds.ps1 cannot fix -- that's a human browser step by
# design) discoverable instead of silently vanishing into Task
# Scheduler's own run history, which nobody checks proactively.
#
# refresh-aws-creds.ps1 calls `exit 1` on failure. Invoking it with `&`
# in-process would take this wrapper's whole process down with it
# before the log write below ever ran -- so it's launched as a real
# child process instead (Start-Process), whose exit code and
# stdout/stderr we can capture after it's gone.
#
# Log: logs\aws-creds-refresh.log, plain text, one line per run,
# newest last. status-check.ps1 reads its last line; a human can just
# open the file.

param(
    [string]$Profile = "cda-admin"
)

$ErrorActionPreference = "Stop"

$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "aws-creds-refresh.log"

$scriptPath = Join-Path $PSScriptRoot "refresh-aws-creds.ps1"
$stdoutFile = Join-Path $env:TEMP "cpde-web-refresh-stdout-$PID.txt"
$stderrFile = Join-Path $env:TEMP "cpde-web-refresh-stderr-$PID.txt"

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# -WorkingDirectory explicitly, not assumed inherited: refresh-aws-
# creds.ps1 shells out to `docker compose`, which resolves
# docker-compose.yml relative to the CURRENT directory -- Start-Process
# does not reliably inherit the caller's location otherwise (found
# live: the task's first real run failed with "no configuration file
# provided: not found" before this was added).
$proc = Start-Process -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath, "-Profile", $Profile) `
    -WorkingDirectory $PSScriptRoot `
    -Wait -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

$stdout = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { "" }
$stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { "" }
Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    "$ts  OK    credentials refreshed" | Add-Content -Path $logFile -Encoding utf8
} else {
    # The single most useful line out of refresh-aws-creds.ps1's own
    # output on failure -- "Run 'aws sso login' first ..." -- so the
    # log entry itself says what to do, not just that something broke.
    $hint = ($stdout + "`n" + $stderr) -split "`n" |
        Where-Object { $_ -match "sso login" } | Select-Object -First 1
    if (-not $hint) { $hint = "see full output below" }
    "$ts  FAIL  exit $($proc.ExitCode) -- $($hint.Trim())" | Add-Content -Path $logFile -Encoding utf8
    "----- full output ($ts) -----" | Add-Content -Path $logFile -Encoding utf8
    ($stdout + $stderr) | Add-Content -Path $logFile -Encoding utf8
    "-----------------------------" | Add-Content -Path $logFile -Encoding utf8
}

exit $proc.ExitCode
