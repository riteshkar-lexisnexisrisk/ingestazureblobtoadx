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

## Known, accepted first-deploy differences

Running `what-if` against the live `itp` resource group before committing
this template showed only additive/benign drift versus the original
portal-created resources: new `tags`, a couple of ARM-computed/read-only
properties being recalculated (e.g. `managedIdentityObjectId` on the data
connection), and the Kusto cluster's `zones` list order. No deletions and no
functional changes were reported.
