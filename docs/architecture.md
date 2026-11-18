# Phase 1 architecture — automated Terraform drift detection

## End-to-end flow

```mermaid
flowchart TD
    subgraph TRIGGER["1 - Trigger"]
        CRON["Scheduled cron<br/>02:00 UTC daily"]
        MANUAL["Manual workflow_dispatch"]
    end

    subgraph ORCH["2 - Central orchestrator repo (this repo)"]
        CONF["repos.json<br/>repositories -> workflows -> environments"]
        PREP["prepare job<br/>validate + jq flatten to matrix"]
        FAN["dispatch job<br/>matrix fan-out, max-parallel = 5, fail-fast = false"]
        CONF --> PREP --> FAN
    end

    CRON --> PREP
    MANUAL --> PREP

    FAN -->|"REST: POST /repos/:owner/:repo/actions/workflows/:file/dispatches<br/>ref = default branch, drift_check_only = true"| RUN

    subgraph TARGET["3 - Target Terraform repositories (default branch only)"]
        RUN["Caller workflow_dispatch<br/>(thin wrapper)"]
        INIT["terraform init"]
        PLAN["terraform plan -detailed-exitcode<br/>-out=tfplan.binary"]
        RUN --> INIT --> PLAN
    end

    PLAN -->|"exit 0"| NODRIFT["No drift<br/>job green, nothing uploaded"]
    PLAN -->|"exit 1"| ERROR["Terraform error<br/>job red -> alerting"]
    PLAN -->|"exit 2"| SHOW["terraform show -json tfplan.binary"]

    SHOW --> JQ["jq filter<br/>drop actions == no-op and actions == read"]
    JQ --> META["Wrap with metadata<br/>repo, workflow, environment, timestamp, run_url"]
    META --> LOGIN["azure/login@v2<br/>OIDC token -> Entra federated credential"]
    LOGIN --> BLOB[("Azure Blob Storage<br/>drift-reports/YYYY-MM-DD/repo-workflow-env.json")]

    BLOB -.-> P2

    subgraph P2["Phase 2 - placeholder, not built in Phase 1"]
        direction TB
        EG["Event Grid<br/>BlobCreated"] -.-> AI["AI analysis"] -.-> TEAMS["Microsoft Teams notification"]
    end
```

## OIDC token exchange (why no storage keys are stored)

```mermaid
sequenceDiagram
    autonumber
    participant TF as Target repo job
    participant GH as GitHub OIDC provider
    participant ENTRA as Entra ID (federated credential)
    participant ST as Azure Blob Storage

    TF->>GH: Request ID token (permissions: id-token: write)
    GH-->>TF: JWT with sub = repo:ORG/REPO:ref:refs/heads/main
    TF->>ENTRA: azure/login@v2 exchanges JWT for an access token
    ENTRA->>ENTRA: Match issuer + subject + audience on the app registration
    ENTRA-->>TF: Access token scoped by RBAC (Storage Blob Data Contributor on drift-reports)
    TF->>ST: az storage blob upload --auth-mode login
    ST-->>TF: 201 Created
```

## Notes that shape the implementation

- **Reusable workflow, thin caller.** All target-side logic lives in
  `.github/workflows/reusable-drift-check.yml`; each Terraform repo holds a
  ~15-line `workflow_dispatch` caller (`examples/target-repo-caller.yml`). The
  orchestrator dispatches the *caller* file, because a reusable workflow cannot
  be dispatched directly.
- **One federated credential per target repo.** With a reusable workflow the
  OIDC `sub` claim identifies the *calling* repository, while
  `job_workflow_ref` identifies the shared workflow. Entra matches `sub` by
  default, so the trust is granted per repository/branch, not once centrally.
- **Immutable subject format.** Repositories created after 2026-07-15 use
  `repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH`. `azure/setup.sh`
  detects the format from `created_at`; with Terraform, set `subject` per entry.
  A mismatch fails closed with `AADSTS70021`.
- **Drift is not a failure.** Exit `2` uploads and stays green; only exit `1`
  (terraform error) turns the job red, so run status remains meaningful.
- **Dispatch is fire-and-forget.** `workflow_dispatch` returns `204` with no run
  id, so traceability comes from the target run writing its own `run_url` and
  the orchestrator run URL into the report metadata.
- **Reports may contain secrets.** `terraform show -json` includes sensitive
  attribute values in plaintext. The container is private, shared key access is
  disabled, and blobs expire after 90 days.
