# install-refresh-task.ps1 -- registers a Windows Scheduled Task that
# runs refresh-aws-creds.ps1 (via scheduled-refresh-wrapper.ps1, for
# logging) every 45 minutes, so the cpdeWebLocalDevRole's ~1-hour STS
# expiry stops interrupting active work.
#
# Does NOT and cannot automate `aws sso login` -- that is a human,
# browser-based approval by design. This only automates the
# assume-role step that happens AFTER a valid SSO session already
# exists; if that base session lapses, the scheduled run fails and
# says so in logs\aws-creds-refresh.log (see check-aws-creds-status.ps1).
#
# WHY 45 MINUTES, NOT 60: real margin ahead of the ~1-hour STS expiry,
# not a task that sometimes fires just after the window has already
# closed.
#
# WHY THE CURRENT USER, NOT SYSTEM: the assume-role step reads this
# user's own cached SSO session (~/.aws/sso/cache) to complete without
# prompting. A SYSTEM-context task has no access to that cache and
# would fail every single run. LogonType Interactive means the task
# fires only while this user is logged on (locked is fine, logged off
# is not) -- exactly the condition under which the cache is usable
# anyway, and it needs no stored password.
#
# Usage:
#   .\install-refresh-task.ps1
#   .\install-refresh-task.ps1 -Profile cda-temp   # non-default SSO profile
#
# To remove: .\uninstall-refresh-task.ps1

param(
    [string]$Profile = "cda-admin",
    [int]$IntervalMinutes = 45
)

$ErrorActionPreference = "Stop"

$TaskName = "cpde-web-aws-creds-refresh"
$wrapperPath = Join-Path $PSScriptRoot "scheduled-refresh-wrapper.ps1"

if (-not (Test-Path $wrapperPath)) {
    Write-Host "scheduled-refresh-wrapper.ps1 not found next to this script -- aborting." -ForegroundColor Red
    exit 1
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Task '$TaskName' already exists -- removing it first so this re-registers cleanly." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# WorkingDirectory matters: refresh-aws-creds.ps1 shells out to
# `docker compose ...`, which resolves docker-compose.yml relative to
# the CURRENT directory, not the script's own location -- Task
# Scheduler's default working directory (System32) has none, which is
# exactly the "no configuration file provided: not found" failure
# this line exists to prevent (found live, during this task's own
# first real run).
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`" -Profile $Profile" `
    -WorkingDirectory $PSScriptRoot

# Fires ~1 minute from now, then repeats indefinitely on the interval.
# Task Scheduler's repetition duration must fit its own XML duration
# format -- [TimeSpan]::MaxValue overflows it (HRESULT 0x80041318).
# 10 years is effectively indefinite for a local dev machine.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Refreshes cpdeWebLocalDevRole credentials (cpde-web local dev) every $IntervalMinutes min. Requires an existing 'aws sso login' session -- does not perform that step itself. See README.md." `
    | Out-Null

Write-Host "`nRegistered scheduled task '$TaskName':" -ForegroundColor Green
Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State
(Get-ScheduledTask -TaskName $TaskName).Triggers | Format-List

Write-Host "Runs as $currentUser, every $IntervalMinutes minutes, first fire in ~1 minute." -ForegroundColor Green
Write-Host "Log: logs\aws-creds-refresh.log  --  check with .\check-aws-creds-status.ps1" -ForegroundColor DarkGray
Write-Host "To remove: .\uninstall-refresh-task.ps1" -ForegroundColor DarkGray
