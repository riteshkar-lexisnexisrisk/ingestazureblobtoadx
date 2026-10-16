# CI/CD pipeline architecture

Diagram of the three GitHub Actions pipelines defined in
[.github/workflows/](/C:/Users/karr/myprojects/ingestazureblobtoadx/.github/workflows),
generated from the actual job graph and `runs-on` targets in that code. For
the data-plane flow this infrastructure implements (blob → Event Grid →
Event Hub → ADX) and how it's verified end-to-end, see
[e2e-ingestion-flow.md](/C:/Users/karr/myprojects/ingestazureblobtoadx/docs/e2e-ingestion-flow.md).

- **Blue** — jobs on GitHub-hosted runners (no Azure access; safe to run
  arbitrary PR code here).
- **Orange** — jobs on the self-hosted runner, authenticated via the
  workstation's own `az login` session (see
  [README.md](/C:/Users/karr/myprojects/ingestazureblobtoadx/README.md#authentication-model-self-hosted-runner-no-service-principal)).
- **Dark-orange diamonds** — human approval gates on protected GitHub
  Environments (`test`, `destroy-shareddev`, `destroy-test`).
- **Green** — the target Azure resource groups.

Every self-hosted (orange) job that touches a deployment (`deploy-shareddev`,
`deploy-test`) first runs a "resolve role definition and role assignment
GUIDs dynamically" step - looking up built-in role IDs by name and any
pre-existing role assignment GUIDs for the target resource group - before
calling `what-if`/`create`, so neither is ever hardcoded (see
["Importing pre-existing role assignments automatically"](/C:/Users/karr/myprojects/ingestazureblobtoadx/README.md#importing-pre-existing-role-assignments-automatically)
in the README). Those same deployments also apply the ADX ingestion schema
(tables, mapping, transform function, policies) from
[adx/scripts/clf-events_capture_ingestion_tables.kql](/C:/Users/karr/myprojects/ingestazureblobtoadx/adx/scripts/clf-events_capture_ingestion_tables.kql) -
see
["ADX (Kusto) schema management"](/C:/Users/karr/myprojects/ingestazureblobtoadx/README.md#adx-kusto-schema-management).

```mermaid
---
id: 51969bd4-cb8d-47af-9d08-f7fb6b45438f
---
flowchart TB
    Dev["Developer opens PR\ntargeting main"] --> PR

    subgraph PR["ci-pr-and-shareddev.yml · on pull_request"]
        direction TB
        P1["security-scan\n(ubuntu-latest)"]
        P2["lint-and-build\n(ubuntu-latest)"]
        P3["unit-tests\n(ubuntu-latest)"]
        P4["e2e-regression\n(self-hosted · az login)"]
        P2 --> P3 --> P4
    end

    PR -->|"merge to main"| Push

    subgraph Push["ci-pr-and-shareddev.yml · on push to main"]
        direction TB
        S1["security-scan"]
        S2["lint-and-build"]
        S3["unit-tests"]
        S4["e2e-regression\n(SharedDev, self-hosted)"]
        S5["deploy-shareddev\n(self-hosted · resolve GUIDs ·\nwhat-if + create · incl. ADX schema)"]
        S6["post-deploy-regression\n(SharedDev, self-hosted)"]
        S2 --> S3 --> S4
        S1 --> S5
        S4 --> S5 --> S6
    end

    Push -->|"itp resource group"| SharedDev[("Azure: SharedDev\nresource group itp")]

    Human["Engineer manually\ntriggers workflow_dispatch"] --> Promote

    subgraph Promote["promote-shareddev-to-test.yml · workflow_dispatch"]
        direction TB
        T0["validate-confirmation\n(type 'promote')"]
        T1["security-scan"]
        T2["unit-tests"]
        T3["verify-shareddev\n(e2e regression, self-hosted)"]
        T4{{"Required reviewer\napproval: test environment"}}
        T5["deploy-test\n(self-hosted · resolve GUIDs ·\nwhat-if + create · incl. ADX schema)"]
        T6["post-deploy-regression\n(Test, self-hosted)"]
        T0 --> T1 & T2 --> T3 --> T4 --> T5 --> T6
    end

    Promote -->|"itp-test resource group"| Test[("Azure: Test\nresource group itp-test")]

    Human2["Engineer manually\ntriggers workflow_dispatch"] --> Destroy

    subgraph Destroy["destroy.yml · workflow_dispatch"]
        direction TB
        D1["resolve-environment\n(validate confirmation text)"]
        D2{{"Required reviewer\napproval: destroy-<env>"}}
        D3["destroy\n(self-hosted · az group delete)"]
        D1 --> D2 --> D3
    end

    Destroy -->|"deletes resource group"| SharedDev
    Destroy -->|"or"| Test

    classDef hosted fill:#DCEEFB,stroke:#3178C6,color:#1A1A1A
    classDef selfhosted fill:#FDEBD0,stroke:#D68910,color:#1A1A1A
    classDef gate fill:#F5CBA7,stroke:#CA6F1E,color:#1A1A1A
    classDef azure fill:#E8F8F5,stroke:#117A65,color:#1A1A1A

    class P1,P2,P3,S1,S2,S3,T1,T2,D1 hosted
    class P4,S4,S5,S6,T3,T5,T6,D3 selfhosted
    class T4,D2 gate
    class SharedDev,Test azure
```
