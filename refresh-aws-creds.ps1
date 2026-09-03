# refresh-aws-creds.ps1 -- assume cpdeWebLocalDevRole and wire the
# resulting temporary credentials into this shell session AND into the
# API container, for real per-client SSM key resolution
# (engine_client.py) during local dev.
#
# Run this BEFORE starting the stack, or any time an SSM-dependent call
# starts failing mid-session with an auth error -- the assumed role's
# credentials expire after about an hour.
#
# WHAT THIS DOES NOT DO: `aws sso login` itself. That is a human,
# browser-based step by design and is not scripted here -- if your SSO
# session has expired, this script fails cleanly and tells you to run
# it, rather than producing a confusing downstream error later.
#
# WHY THE ROLE ARN IS HARDCODED, NOT INFERRED: a prior session exported
# a developer's personal admin SSO session instead of the scoped
# cpdeWebLocalDevRole by mistake. Testing code under admin access proves
# nothing about whether the actually-scoped role works, and can mask a
# permissions bug that would only surface in production. Hardcoding the
# target role here, and verifying the resolved identity out loud after
# assuming it, makes that class of mistake structurally harder to repeat
# -- not just something to remember not to do.
#
# Usage:
#   .\refresh-aws-creds.ps1
#   .\refresh-aws-creds.ps1 -Profile cda-temp   # if your base SSO
#                                                # session lives under a
#                                                # named profile, not
#                                                # the default one

param(
    [string]$Profile = ""
)

$ErrorActionPreference = "Stop"

# Hardcoded on purpose -- see the file header. Never infer this from
# whatever profile or session happens to be active.
$RoleArn = "arn:aws:iam::087722400628:role/cpdeWebLocalDevRole"
$SessionName = "cpde-web-local"

$profileArgs = @()
if ($Profile) { $profileArgs = @("--profile", $Profile) }

Write-Host "Assuming $RoleArn ..." -ForegroundColor Cyan

# Deliberately no 2>&1 here -- in PowerShell 5.1 that wraps a native
# exe's stderr in a NativeCommandError and hides the actual message
# behind a generic RemoteException. Let stderr print to the console
# directly (that IS the useful "why it failed" detail) and just check
# the exit code and stdout.
$assumeJson = aws sts assume-role `
    --role-arn $RoleArn `
    --role-session-name $SessionName `
    --output json `
    @profileArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nCould not assume cpdeWebLocalDevRole (see the AWS CLI " -ForegroundColor Red
    Write-Host "error above)." -ForegroundColor Red
    Write-Host "`nRun 'aws sso login' first (with -Profile if your SSO " -ForegroundColor Yellow
    Write-Host "session lives under a named profile), then re-run this script." -ForegroundColor Yellow
    exit 1
}

$creds = ($assumeJson | Out-String | ConvertFrom-Json).Credentials
if (-not $creds -or -not $creds.AccessKeyId) {
    Write-Host "`nassume-role returned no usable credentials -- unexpected " -ForegroundColor Red
    Write-Host "response shape. Nothing was exported." -ForegroundColor Red
    exit 1
}

# ---- 1. export into THIS shell session -----------------------------
$env:AWS_ACCESS_KEY_ID = $creds.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $creds.SecretAccessKey
$env:AWS_SESSION_TOKEN = $creds.SessionToken

# ---- 2. export into the API container's environment ----------------
# docker-compose.yml has no env_file: directive -- it uses inline
# environment: blocks with ${VAR} interpolation, which docker compose
# resolves from a .env file sitting next to it (its own built-in
# convention, no extra config needed). .gitignore already excludes
# .env / *.env, so this never risks landing in git.
$envFile = Join-Path $PSScriptRoot ".env"
@"
AWS_ACCESS_KEY_ID=$($creds.AccessKeyId)
AWS_SECRET_ACCESS_KEY=$($creds.SecretAccessKey)
AWS_SESSION_TOKEN=$($creds.SessionToken)
"@ | Set-Content -Path $envFile -Encoding utf8 -NoNewline

Write-Host "Wrote temporary credentials to $envFile (gitignored)." -ForegroundColor DarkGray

# Only recreate the API container if the stack is already up -- this
# script also needs to work as the FIRST thing run before anything is
# started at all.
$apiRunning = docker compose ps api --status running -q 2>$null
if ($apiRunning) {
    Write-Host "Recreating the api container to pick up the new credentials..." -ForegroundColor Cyan
    docker compose up -d api | Out-Null
} else {
    Write-Host "Stack not running yet -- credentials will apply when you start it." -ForegroundColor DarkGray
}

# ---- 3. verify with THESE credentials, out loud ---------------------
Write-Host "`nVerifying identity with the assumed credentials..." -ForegroundColor Cyan
$identityJson = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nget-caller-identity FAILED using the freshly assumed " -ForegroundColor Red
    Write-Host "credentials (see the AWS CLI error above) -- something is " -ForegroundColor Red
    Write-Host "wrong; do not trust this session." -ForegroundColor Red
    exit 1
}
$identity = $identityJson | Out-String | ConvertFrom-Json

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " You are now:  $($identity.Arn)" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green

if ($identity.Arn -notmatch "cpdeWebLocalDevRole") {
    Write-Host "`nWARNING: resolved identity does NOT mention cpdeWebLocalDevRole." -ForegroundColor Red
    Write-Host "This is NOT the scoped role -- stop and investigate before using" -ForegroundColor Red
    Write-Host "these credentials for anything." -ForegroundColor Red
    exit 1
}

$expiry = [DateTime]$creds.Expiration
# PowerShell's implicit [DateTime] cast on an offset-aware ISO 8601
# string (e.g. "...+00:00") converts it to LOCAL wall-clock time AND
# sets Kind=Local -- it is already local, not UTC. Subtracting it from
# (Get-Date).ToUniversalTime() silently mixed Local and Utc clock
# values with no Kind-aware adjustment, producing a nonsense negative
# result. Compare local-to-local instead.
$minutesLeft = [Math]::Round(($expiry - (Get-Date)).TotalMinutes)
Write-Host "`nExpires at $expiry (~$minutesLeft minutes from now)." -ForegroundColor Yellow
Write-Host "Re-run this script when an SSM-dependent call starts failing with" -ForegroundColor Yellow
Write-Host "an auth error, or proactively before then." -ForegroundColor Yellow
