# uninstall-refresh-task.ps1 -- removes the scheduled credential-refresh
# task registered by install-refresh-task.ps1. Safe to run even if the
# task was never installed (reports that plainly and exits 0).
#
# Does not touch logs\aws-creds-refresh.log or the .env file -- only
# the Scheduled Task registration itself.

$TaskName = "cpde-web-aws-creds-refresh"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "Task '$TaskName' is not registered -- nothing to remove." -ForegroundColor Yellow
    exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
