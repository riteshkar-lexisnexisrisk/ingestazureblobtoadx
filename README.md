# Blob → Event Grid → Event Hub → Azure Data Explorer ingestion (IaC + CI/CD)

Infrastructure-as-code and CI/CD for the `itp` ingestion pipeline: blobs
landing in Azure Storage raise Event Grid events, which are routed through an
Event Hub into an Azure Data Explorer (Kusto) cluster via a managed-identity
data connection.

```
Storage Account (clf container)
        │  Microsoft.Storage.BlobCreated / BlobDeleted
        ▼
Event Grid System Topic ──event subscription──► Event Hub (clf-evh-capture-blob-events)
        │ (miitpeg* identity: Event Hubs Data Sender)        │ consumer group: itpadxevhcaptureblobeventsconsumer
                                                              ▼
                                      Azure Data Explorer cluster (itpadx*)
                                      ├─ database: clf-event-capture  (data connection: itp-evg-adx-connection)
                                      └─ database: clf-events
                                      (miitpadx* identity: Storage Blob Data Reader + Event Hubs Data Receiver)
```

An `Microsoft.EventGrid/namespaces` resource (`egitp*`) is also captured for
parity with the portal-created environment; it is not currently wired into
the event subscription (the subscription hangs off the system topic) and is
reserved for future custom-topic/MQTT use.

## Repository layout

```
infra/
  main.bicep                 Orchestrates all modules + RBAC for one environment
  modules/
    managedIdentity.bicep
    storage.bicep
    eventHub.bicep
    eventGrid.bicep
    kusto.bicep
  parameters/
    shareddev.bicepparam      Matches the original portal-created resources 1:1
    test.bicepparam           Distinct names for an isolated Test environment
tests/
  unit/Infra.Tests.ps1        Pester: bicep lint/build, naming, RBAC presence (no Azure deployment)
  e2e/Regression.Tests.ps1    Pester: live checks against a deployed resource group
adx/
  scripts/
    clf-events_capture_ingestion_tables.kql  KQL schema script: raw Avro ingestion
                                              table + mapping, JSON transform function,
                                              derived table + update policy, batching
                                              policy. Deployed via main.bicep (see
                                              "ADX (Kusto) schema management" below).
scripts/
  setup-self-hosted-runner.ps1  One-time, manual: install a GitHub Actions self-hosted
                                 runner on this workstation, using your own `az login`
                                 session (current default - no app registration needed)
  setup-github-oidc.ps1         Alternative, manual: Entra app + federated creds + RBAC,
                                 only needed if you switch the Azure-touching jobs back
                                 to GitHub-hosted runners
.github/workflows/
  ci-pr-and-shareddev.yml           PR validation + auto-promote LocalDev → SharedDev
  promote-shareddev-to-test.yml     Manual: SharedDev → Test
  destroy.yml                       Manual: tear down an environment's resource group
```

## Environments

| Environment | Resource group | Parameter file                        | How it's reached |
|-------------|-----------------|----------------------------------------|------------------|
| LocalDev    | *(no Azure RG)* | n/a                                     | Developer's branch; validated via `what-if` / unit tests locally or in a PR |
| SharedDev   | `itp`           | `infra/parameters/shareddev.bicepparam` | Auto-deployed when a PR merges to `main` |
| Test        | `itp-test`      | `infra/parameters/test.bicepparam`      | Manually promoted from SharedDev |

SharedDev's parameter file intentionally reuses the exact resource names that
already exist in the portal-created `itp` resource group, so the first
pipeline run reconciles/imports them in place rather than creating
duplicates. This was validated with `az deployment group what-if` against the
live subscription before being committed (see `git log`/PR history).

### Importing pre-existing role assignments automatically

If a resource group's managed identities already have role assignments
granted manually (e.g. via the portal) before it was adopted into Bicep -
as was the case for `itp`/SharedDev - those assignments exist under random
GUID names that won't match the deterministic GUIDs Bicep would otherwise
compute. Deploying as-is then fails with `RoleAssignmentExists`, because
Azure RBAC rejects a second assignment for the same (principal, role, scope)
tuple regardless of name.

This is handled automatically, with no environment-specific configuration
needed: the `deploy-shareddev`/`deploy-test` jobs run a "Resolve role
definition and role assignment GUIDs dynamically" step before every
deployment, which resolves two different kinds of GUID, neither of which is
ever hardcoded in `main.bicep`:

1. **Role assignment names** - looked up (via `az identity show` +
   `az role assignment list`) to check whether each of the 3
   identity/role/scope combinations this template manages already has an
   assignment in the target resource group. Any match found is passed into
   the `existingRoleAssignmentIds` Bicep parameter so the deployment updates
   it in place; anything not found resolves to an empty value, and
   `main.bicep` falls back to computing a fresh, deterministic, conflict-free
   GUID.
2. **Built-in role definition IDs** (e.g. "Storage Blob Data Reader") -
   although these are global constants published by Microsoft (identical in
   every subscription/tenant), they're still resolved by name via
   `az role definition list --name "<role name>"` rather than pinned as a
   literal GUID in Bicep, so the workflow keeps working unmodified even if
   Microsoft were ever to change one. `main.bicep` still carries the current
   documented values as parameter *defaults*, purely as a fallback for
   direct/local deployments that bypass the pipeline.

This makes the same template portable to a brand-new environment or
subscription without any manual lookup or per-environment parameter file
changes.

### ADX (Kusto) schema management

The `clf-event-capture` database's ingestion schema - the raw Avro table
(`clf_events_capture_blobs_avro`), its ingestion mapping
(`clf_events_capture_blobs_avro_mapping`), the `DecodeAvroToJsonEventBody()`
transform function, the derived JSON table
(`clf_events_capture_blobs_json`) with its update policy, and the ingestion
batching policy - is defined in
[adx/scripts/clf-events_capture_ingestion_tables.kql](/C:/Users/karr/myprojects/ingestazureblobtoadx/adx/scripts/clf-events_capture_ingestion_tables.kql)
and deployed declaratively via a `Microsoft.Kusto/clusters/databases/scripts`
resource in `infra/modules/kusto.bicep` (loaded at compile time with
`loadTextContent()` - no separate upload/publish step required).

This script's commands (`.create-merge table`, `.create-or-alter
function`/`mapping`/`policy`) are all idempotent, so the script reapplies on
every deployment (`forceUpdateTag` defaults to the deployment timestamp) -
this also self-heals any manual, out-of-band changes to the schema back to
what's committed in source control. The Event Grid data connection's
`tableName`/`mappingRuleName` point at this same raw ingestion table/mapping,
and the resource that runs the script is declared as a dependency of the
data connection so the table/mapping are guaranteed to exist first.

To add or change tables, functions, mappings, or policies, edit the `.kql`
script and commit - no other file needs to change. The identity used to run
the deployment (currently your own `az login` session, per the
self-hosted-runner model below) must already be a Database Admin on the
target Kusto database for the script to succeed; this is normally already
the case for whoever did the original cluster/database deployment.

> **Important:** `principalPermissionsAction` on the script resource is set
> to `RetainPermissionOnScriptCompletion`, not `RemovePermissionOnScriptCompletion`.
> `Remove` was tried first and found (empirically, during testing) to strip
> the *entire* Database Admin role assignment for the deploying principal
> after the script completes - not just the temporary elevation the script
> itself needed - which locks that identity out of both future pipeline
> deployments (which need write access to redeploy this very script) and
> interactive Data Explorer access in the portal. If this identity ever
> loses Database Admin access again, restore it via:
> `az kusto database-principal-assignment create -g <rg> --cluster-name <cluster> --database-name clf-event-capture --principal-assignment-name <name> --principal-id <upn-or-object-id> --principal-type User --role Admin --tenant-id <tenant-id>`.

## CI/CD pipelines

See [docs/pipeline-architecture.md](/C:/Users/karr/myprojects/ingestazureblobtoadx/docs/pipeline-architecture.md)
for a diagram of the full job graph across all three workflows.

### 1. `ci-pr-and-shareddev.yml` — PR validation + promote to SharedDev
Triggers on `pull_request` (targeting `main`) and `push` to `main`.

1. **security-scan** — Microsoft Security DevOps (Template Analyzer + secret
   scanning) on every PR and push; results upload to GitHub code scanning.
2. **lint-and-build** — `az bicep build` for `main.bicep` and every module;
   `az bicep build-params` for every environment parameter file.
3. **unit-tests** — `tests/unit/Infra.Tests.ps1` (no Azure calls beyond the
   Bicep CLI; safe to run on every PR from any branch).
4. **e2e-regression** — `tests/e2e/Regression.Tests.ps1` against the live
   SharedDev resource group, to catch regressions *before* merging.
5. **deploy-shareddev** *(push to `main` only)* — `what-if` preview then
   `az deployment group create` against `itp`.
6. **post-deploy-regression** *(push to `main` only)* — re-runs the e2e suite
   against SharedDev after the deploy to confirm the promotion didn't break
   anything.

### 2. `promote-shareddev-to-test.yml` — manual SharedDev → Test
`workflow_dispatch`, requires typing `promote` to confirm. Re-runs the
security scan, unit tests, and SharedDev e2e regression suite (ensuring
"all scans and tests have passed") before deploying the same templates to
`itp-test`, then runs the e2e suite again against Test.

Both `deploy-shareddev` and `deploy-test` use `az deployment group create`
in its default **Incremental** mode (not `Complete`), so repeated promotions
are non-destructive: existing resources are updated in place, nothing
outside the template is deleted, and you never need to run `destroy.yml`
before promoting new changes. The `what-if` preview that runs just before
every deploy is your safety check - review it for any `-` (delete) or
replace operations before they apply, though none of the current modules
require resource replacement for in-place property changes.

### 3. `destroy.yml` — manual teardown
`workflow_dispatch`, choose `shareddev` or `test` and type the exact resource
group name (`itp` / `itp-test`) to confirm. Deletes the whole resource group.
Mapped to a `destroy-<environment>` GitHub Environment so it can require
separate (stricter) approvers than normal deploys.

## Authentication model: self-hosted runner, no service principal

The Azure-touching jobs (`e2e-regression`, `deploy-shareddev`,
`post-deploy-regression`, `verify-shareddev`, `deploy-test`, `destroy`) run on
a **self-hosted GitHub Actions runner installed on your workstation**
(`runs-on: self-hosted`) and authenticate to Azure using **your own,
already-logged-in `az login` session** — there is no Entra ID app
registration, service principal, client secret, or OIDC federated credential
to create or rotate. The non-Azure jobs (`security-scan`, `lint-and-build`,
`unit-tests`, `resolve-environment`) still run on GitHub-hosted runners, both
for speed and so that arbitrary PR code never executes on your machine.

Tradeoffs to be aware of:
- **Availability** — the runner (and therefore the auto-deploy-on-merge and
  manual promote/destroy pipelines) only works while your workstation is on
  and the runner process is running.
- **Session expiry** — `az login` sessions expire periodically (commonly
  ~90 days, sooner under Conditional Access/MFA policies). If a pipeline run
  fails with an auth error, just run `az login` again on the workstation.
- **Security** — the runner executes workflow code with your own (Owner)
  Azure credentials on your own machine. Keep this repository private and
  don't add untrusted collaborators/forks while using this model.

## One-time setup required before the pipelines can run

1. **Install and register the self-hosted runner** (uses your existing Azure
   CLI login - you already have `Owner` on this subscription, so no role
   assignments are needed):
   ```powershell
   ./scripts/setup-self-hosted-runner.ps1 -SubscriptionId a2a8d07d-bc4a-4483-ad5a-21de20170904
   ```
   Follow the printed instructions to register the runner with GitHub
   (Settings → Actions → Runners → New self-hosted runner) and start it with
   `run.cmd` in a session where `az login` is already active (don't install
   it as a Windows service, since that typically runs under a different,
   non-interactive account that won't see your cached Azure CLI token).

2. **GitHub Environments** (Settings → Environments): create `shareddev`,
   `test`, `destroy-shareddev`, `destroy-test`. Add **required reviewers** to
   `test`, `destroy-shareddev`, and `destroy-test` so promotions/destroys
   pause for human approval; `shareddev` can auto-deploy without a reviewer
   since it's gated by the PR review + passing checks.

3. Branch protection on `main`: require the `security-scan`,
   `lint-and-build`, `unit-tests`, and `e2e-regression` checks to pass before
   a PR can be merged.

> Prefer GitHub-hosted runners with OIDC instead? Run
> `./scripts/setup-github-oidc.ps1` and switch the Azure-touching jobs'
> `runs-on:` back to `ubuntu-latest`, re-adding an `azure/login@v2` step with
> `client-id`/`tenant-id`/`subscription-id` secrets — see that script's header
> comment for details.

## Running tests locally

```powershell
# Unit tests (no Azure access required)
Invoke-Pester tests/unit/Infra.Tests.ps1 -Output Detailed

# End-to-end regression tests (requires az login with read access to the target RG)
Invoke-Pester -Container (New-PesterContainer -Path tests/e2e/Regression.Tests.ps1 -Data @{
    ResourceGroup = 'itp'
    ParameterFile = 'infra/parameters/shareddev.bicepparam'
}) -Output Detailed
```

The ADX ingestion functional test (in `Regression.Tests.ps1`) uploads
`tests/sampledata/32.avro` (a real Event Hub Capture-format sample file),
waits for the ADX data connection to ingest it (polling, since ingestion is
batched - see the ingestion batching policy in the `.kql` script above), and
verifies the ingested row via the `sourceLocation` column before cleaning up
both the blob and the ADX records. It talks to Kusto directly over its REST
API (`/v1/rest/query` and `/v1/rest/mgmt`), authenticated with the same
`az login` session as everything else - no extra setup needed beyond what's
already required for the other e2e tests. If ingestion doesn't complete
within the poll window, the test queries `.show ingestion failures` for that
specific blob and includes the details in the failure message.

## Known, accepted first-deploy differences

Running `what-if` against the live `itp` resource group before committing
this template showed only additive/benign drift versus the original
portal-created resources: new `tags`, a couple of ARM-computed/read-only
properties being recalculated (e.g. `managedIdentityObjectId` on the data
connection), and the Kusto cluster's `zones` list order. No deletions and no
functional changes were reported.
