# check-aws-creds-status.ps1 -- what did the scheduled credential
# refresh last do? Reads logs\aws-creds-refresh.log (written by
# scheduled-refresh-wrapper.ps1) and prints a one-line verdict plus the
# last few entries -- run this any time an SSM call is failing and you
# want to know whether the background refresh is even working, before
# chasing anything else.
#
# Safe to run any time, whether or not the scheduled task is installed.

$logFile = Join-Path $PSScriptRoot "logs\aws-creds-refresh.log"

if (-not (Test-Path $logFile)) {
    Write-Host "No refresh log yet at $logFile." -ForegroundColor Yellow
    Write-Host "Either the scheduled task hasn't fired yet, or it isn't installed -- see install-refresh-task.ps1." -ForegroundColor Yellow
    exit 1
}

$lines = Get-Content $logFile | Where-Object { $_ -match "^\d{4}-\d{2}-\d{2}" }
if (-not $lines) {
    Write-Host "Log file exists but has no run entries yet." -ForegroundColor Yellow
    exit 1
}

$last = $lines[-1]
Write-Host "`nLast 5 scheduled refresh runs:" -ForegroundColor Cyan
$lines | Select-Object -Last 5 | ForEach-Object {
    if ($_ -match "  OK    ") { Write-Host $_ -ForegroundColor Green }
    else { Write-Host $_ -ForegroundColor Red }
}

if ($last -match "  OK    ") {
    $ts = [DateTime]::ParseExact(($last -split "  ")[0], "yyyy-MM-dd HH:mm:ss", $null)
    $ageMin = [Math]::Round(((Get-Date) - $ts).TotalMinutes)
    Write-Host "`nLast refresh succeeded, $ageMin minute(s) ago." -ForegroundColor Green
    if ($ageMin -gt 60) {
        Write-Host "That's over an hour ago -- the scheduled task may not be running. Check with:" -ForegroundColor Yellow
        Write-Host "  Get-ScheduledTask -TaskName cpde-web-aws-creds-refresh" -ForegroundColor Yellow
    }
    exit 0
} else {
    Write-Host "`nLast scheduled refresh FAILED. Run '.\refresh-aws-creds.ps1' by hand to see the full error, and if it says to, run 'aws sso login' first." -ForegroundColor Red
    exit 1
}
