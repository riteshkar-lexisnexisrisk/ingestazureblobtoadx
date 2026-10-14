<#
.SYNOPSIS
    ALTERNATIVE setup (not the current default - see
    scripts/setup-self-hosted-runner.ps1 and README.md). Creates (or reuses)
    a Microsoft Entra ID app registration with federated credentials for
    GitHub-hosted-runner OIDC login, and grants it Contributor on the
    resource groups used by each environment.

.DESCRIPTION
    The pipelines currently run on a self-hosted runner using your own
    Azure CLI session (see scripts/setup-self-hosted-runner.ps1), so this
    script is not required. Keep it around in case you later move the
    Azure-touching jobs back to GitHub-hosted runners (runs-on: ubuntu-latest)
    and want OIDC federation instead of a self-hosted runner.

    This script is NOT run automatically by any pipeline. Run it once,
    interactively, as a subscription Owner/User Access Administrator, before
    the pipelines can authenticate to Azure. It creates:
      - One app registration / service principal: "github-ingestazureblobtoadx"
      - Federated credentials scoped to:
          * pull_request events on this repo   (used by PR validation jobs)
          * the "shareddev" GitHub Environment  (used by SharedDev deploy jobs)
          * the "test" GitHub Environment       (used by Test deploy jobs)
          * the "destroy-shareddev" and "destroy-test" GitHub Environments
      - Contributor role assignment scoped to each target resource group
        (control-plane only; no secrets or client credentials are created).

    After running, add the printed client-id / tenant-id / subscription-id as
    GitHub Actions secrets (repo or per-environment), and create the GitHub
    Environments listed above with the required-reviewers protection rules
    described in README.md.

.PARAMETER GitHubOrg
    GitHub organization/user that owns the repository, e.g. "karr_risk".

.PARAMETER GitHubRepo
    Repository name, e.g. "ingestazureblobtoadx".

.PARAMETER SubscriptionId
    Azure subscription ID that hosts the resource groups.
#>
param(
    [Parameter(Mandatory = $true)][string]$GitHubOrg,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [string]$AppDisplayName = 'github-ingestazureblobtoadx'
)

$ErrorActionPreference = 'Stop'

Write-Host "Creating/reusing app registration '$AppDisplayName'..."
$app = az ad app list --display-name $AppDisplayName -o json | ConvertFrom-Json
if (-not $app) {
    $app = az ad app create --display-name $AppDisplayName -o json | ConvertFrom-Json
}
else {
    $app = $app[0]
}

$sp = az ad sp list --filter "appId eq '$($app.appId)'" -o json | ConvertFrom-Json
if (-not $sp) {
    $sp = az ad sp create --id $app.appId -o json | ConvertFrom-Json
}
else {
    $sp = $sp[0]
}

$federatedCredentials = @(
    @{ name = 'pull-requests'; subject = "repo:$GitHubOrg/${GitHubRepo}:pull_request" },
    @{ name = 'main-branch'; subject = "repo:$GitHubOrg/${GitHubRepo}:ref:refs/heads/main" },
    @{ name = 'env-shareddev'; subject = "repo:$GitHubOrg/${GitHubRepo}:environment:shareddev" },
    @{ name = 'env-test'; subject = "repo:$GitHubOrg/${GitHubRepo}:environment:test" },
    @{ name = 'env-destroy-shareddev'; subject = "repo:$GitHubOrg/${GitHubRepo}:environment:destroy-shareddev" },
    @{ name = 'env-destroy-test'; subject = "repo:$GitHubOrg/${GitHubRepo}:environment:destroy-test" }
)

foreach ($cred in $federatedCredentials) {
    Write-Host "Ensuring federated credential '$($cred.name)'..."
    $existing = az ad app federated-credential list --id $app.appId -o json | ConvertFrom-Json |
        Where-Object { $_.name -eq $cred.name }

    $body = @{
        name        = $cred.name
        issuer      = 'https://token.actions.githubusercontent.com'
        subject     = $cred.subject
        audiences   = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress

    if ($existing) {
        az ad app federated-credential update --id $app.appId --federated-credential-id $cred.name --parameters $body | Out-Null
    }
    else {
        az ad app federated-credential create --id $app.appId --parameters $body | Out-Null
    }
}

$resourceGroups = @(
    @{ name = 'itp'; location = 'eastus' },
    @{ name = 'itp-test'; location = 'eastus' }
)
foreach ($rg in $resourceGroups) {
    $exists = az group show --name $rg.name --subscription $SubscriptionId 2>$null
    if (-not $exists) {
        Write-Host "Resource group '$($rg.name)' does not exist yet; creating it now so the pipeline's Contributor grant can be scoped to it (rather than the whole subscription)."
        az group create --name $rg.name --location $rg.location --subscription $SubscriptionId | Out-Null
    }
    Write-Host "Granting Contributor on resource group '$($rg.name)'..."
    az role assignment create `
        --assignee-object-id $sp.id `
        --assignee-principal-type ServicePrincipal `
        --role Contributor `
        --scope "/subscriptions/$SubscriptionId/resourceGroups/$($rg.name)" | Out-Null

    # The Bicep templates create role assignments (RBAC) for the managed
    # identities they provision. Contributor alone cannot write role
    # assignments, so grant the narrower "Role Based Access Control
    # Administrator" role (scoped to the same resource group only) in
    # addition to Contributor.
    Write-Host "Granting Role Based Access Control Administrator on resource group '$($rg.name)'..."
    az role assignment create `
        --assignee-object-id $sp.id `
        --assignee-principal-type ServicePrincipal `
        --role 'Role Based Access Control Administrator' `
        --scope "/subscriptions/$SubscriptionId/resourceGroups/$($rg.name)" | Out-Null
}

Write-Host ""
Write-Host "Done. Add these as GitHub Actions secrets (Settings > Secrets and variables > Actions):"
Write-Host "  AZURE_CLIENT_ID       = $($app.appId)"
Write-Host "  AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SubscriptionId"
Write-Host ""
Write-Host "Then create GitHub Environments: shareddev, test, destroy-shareddev, destroy-test"
Write-Host "(Settings > Environments) with required-reviewer protection rules as described in README.md."
