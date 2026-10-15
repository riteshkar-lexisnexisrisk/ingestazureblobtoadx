<#
.SYNOPSIS
    One-time setup: installs a GitHub Actions self-hosted runner on this
    workstation and verifies it can use your existing Azure CLI session,
    so the pipelines need no app registration / service principal.

.DESCRIPTION
    This script is NOT run automatically by any pipeline. Run it once,
    interactively, on the workstation that will execute the Azure-touching
    jobs (e2e-regression, deploy-shareddev, verify-shareddev, deploy-test,
    post-deploy-regression, destroy). It:
      1. Confirms you have an active "az login" session and that it can see
         the target subscription (your user account is already Owner on
         this subscription, so no role assignments are needed).
      2. Downloads and unpacks the GitHub Actions runner into
         $RunnerDirectory (default: $HOME\actions-runner).
      3. Prints the exact "config.cmd" command to run using a registration
         token you copy from the GitHub UI (Settings > Actions > Runners >
         New self-hosted runner) - this token is short-lived and tied to
         your GitHub permissions, so it is not something this script can
         safely fetch on your behalf without a stored GitHub PAT.
      4. Explains how to start the runner so it inherits your logged-in
         Azure CLI session (run interactively / at-logon, NOT as a Windows
         service running under a different, non-interactive account).

.PARAMETER SubscriptionId
    Azure subscription ID the pipelines deploy into.

.PARAMETER RunnerDirectory
    Local folder to install the runner into. Defaults to "$HOME\actions-runner".

.PARAMETER RunnerVersion
    GitHub Actions runner release version to download.

.PARAMETER Labels
    Comma-separated extra labels to register the runner with (in addition to
    the default "self-hosted" label already matched by the workflows'
    `runs-on: self-hosted`).
#>
param(
    [string]$SubscriptionId = 'a2a8d07d-bc4a-4483-ad5a-21de20170904',
    [string]$RunnerDirectory = (Join-Path $HOME 'actions-runner'),
    [string]$RunnerVersion = '2.321.0',
    [string]$Labels = ''
)

$ErrorActionPreference = 'Stop'

Write-Host "Step 1: Verifying Azure CLI session..." -ForegroundColor Cyan
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "No active 'az login' session found. Launching interactive login now..." -ForegroundColor Yellow
    az login | Out-Null
    $account = az account show -o json | ConvertFrom-Json
}
Write-Host "Logged in as $($account.user.name) (tenant $($account.tenantId))"

az account set --subscription $SubscriptionId
$roles = az role assignment list --assignee $account.user.name --scope "/subscriptions/$SubscriptionId" -o json | ConvertFrom-Json
if ($roles.Count -gt 0) {
    Write-Host "Existing subscription-level role(s) for $($account.user.name): $($roles.roleDefinitionName -join ', ')" -ForegroundColor Green
}
else {
    Write-Host "No subscription-level roles found for $($account.user.name) - check resource-group-scoped roles are sufficient for 'itp' and 'itp-test', or grant Contributor + 'Role Based Access Control Administrator' there." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Step 2: Downloading GitHub Actions runner v$RunnerVersion to $RunnerDirectory..." -ForegroundColor Cyan
if (-not (Test-Path $RunnerDirectory)) {
    New-Item -ItemType Directory -Path $RunnerDirectory | Out-Null
}
$zipPath = Join-Path $RunnerDirectory "actions-runner-win-x64-$RunnerVersion.zip"
if (-not (Test-Path $zipPath)) {
    $url = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
    Invoke-WebRequest -Uri $url -OutFile $zipPath
}
Expand-Archive -Path $zipPath -DestinationPath $RunnerDirectory -Force

Write-Host ""
Write-Host "Step 3: Register the runner with GitHub (manual, one-time):" -ForegroundColor Cyan
Write-Host "  1. Open https://github.com/riteshkar-lexisnexisrisk/ingestazureblobtoadx/settings/actions/runners/new"
Write-Host "  2. Copy the registration token shown there, then run from $RunnerDirectory :"
$labelArg = if ($Labels) { " --labels $Labels" } else { '' }
Write-Host "       .\config.cmd --url https://github.com/riteshkar-lexisnexisrisk/ingestazureblobtoadx --token <PASTE_TOKEN_HERE>$labelArg"
Write-Host ""
Write-Host "Step 4: Start the runner so it inherits this Azure CLI session:" -ForegroundColor Cyan
Write-Host "  IMPORTANT: do NOT install it as a Windows service (config.cmd's 'run as service'"
Write-Host "  option) if you want it to reuse this interactive 'az login' token cache - a"
Write-Host "  Windows service normally runs under a different, non-interactive profile."
Write-Host "  Instead, keep a terminal open and run:"
Write-Host "       .\run.cmd"
Write-Host "  or schedule '$RunnerDirectory\run.cmd' to start at your own logon via Task Scheduler"
Write-Host "  (action: run.cmd, trigger: at log on, run only when user is logged on)."
Write-Host ""
Write-Host "Remember: your 'az login' session will eventually expire (commonly ~90 days, or" -ForegroundColor Yellow
Write-Host "sooner under Conditional Access/MFA policies). If the automatic SharedDev deploy" -ForegroundColor Yellow
Write-Host "job starts failing with an auth error, just run 'az login' again on this machine." -ForegroundColor Yellow
