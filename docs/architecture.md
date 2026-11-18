# Phase 1 architecture — automated Terraform drift detection

## End-to-end flow

```mermaid
flowchart TD
    subgraph TRIGGER["1 - Trigger"]
        CRON["Scheduled cron<br/>02:00 UTC daily"]
        MANUAL["Manual workflow_dispatch"]
    end

    subgraph ORCH["2 - Orchestrator repo (this repo)"]
        CONF["repos.json<br/>repo -> workflow -> targets[].dispatch_inputs"]
        PREP["prepare job<br/>validate + jq flatten to matrix"]
        FAN["dispatch job<br/>one job per target, max-parallel = 1..10<br/>+ discover the created run"]
        VERIFY["verify job<br/>poll each dispatched run until completed"]
        CONF --> PREP --> FAN
    end

    CRON --> PREP
    MANUAL --> PREP

    FAN -->|"POST /repos/:owner/:repo/actions/workflows/:file/dispatches<br/>ref = default branch<br/>inputs = environment, azresource, terraformAction=plan"| RUN
    FAN -->|"run id + url (artifact)"| VERIFY
    VERIFY -->|"GET /repos/:owner/:repo/actions/runs/:id<br/>until status = completed"| RUN
    VERIFY -->|"conclusion != success, or run never identified"| SWEEPRED["Sweep fails<br/>(no false green)"]

    subgraph TARGET["3 - Existing target pipeline (unchanged except the plan step)"]
        RUN["workflow_dispatch entry point<br/>(already exists)"]
        STATE["Setup terraform remote state<br/>az group / storage container / sttfst lookup"]
        PLAN["terraform plan -detailed-exitcode -out=tfplan.binary"]
        RUN --> STATE --> PLAN
    end

    PLAN -->|"exit 0"| NODRIFT["No drift<br/>run green, nothing uploaded"]
    PLAN -->|"exit 1"| ERROR["Terraform error<br/>run red -> alerting"]
    PLAN -->|"exit 2"| SHOW["terraform show -json tfplan.binary"]

    SHOW --> JQ["jq filter<br/>drop actions == no-op and actions == read"]
    JQ --> META["Wrap with metadata<br/>repo, workflow, environment, timestamp, run_url"]
    META --> BLOB[("Blob storage in the state account<br/>&lt;DRIFT_CONTAINER&gt;/drift-reports/YYYY-MM-DD/<br/>owner__repo-landingzone-azresource-env.json")]

    BLOB -.-> P2

    subgraph P2["Phase 2 - placeholder, not built in Phase 1"]
        direction TB
        EG["Event Grid<br/>BlobCreated"] -.-> AI["AI analysis"] -.-> TEAMS["Microsoft Teams notification"]
    end
```

## Dispatch and verification sequence

```mermaid
sequenceDiagram
    autonumber
    participant O as Orchestrator (prepare + dispatch jobs)
    participant API as GitHub API
    participant T as Existing target pipeline
    participant AZ as Azure (OIDC)
    participant B as Blob storage

    O->>API: GET /repos/:owner/:repo/actions/workflows/:file (preflight)
    O->>API: GET .../runs?event=workflow_dispatch&branch=main (baseline)
    O->>API: POST .../dispatches {ref, inputs}
    API-->>O: 204 (no run id)
    API->>T: start the workflow that already exists on main
    T->>AZ: azure/login (federated credential for refs/heads/main)
    T->>AZ: terraform init (backend: rg-tfstate / tfstate-infra-env / key per azresource)
    T->>AZ: terraform plan -detailed-exitcode
    alt exit 2 (drift)
        T->>T: terraform show -json | jq filter
        T->>B: az storage blob upload --auth-mode login
        B-->>T: exists = True
    else exit 1 (terraform error)
        T-->>T: job fails, plan log artifact kept
    end
    O->>API: GET .../runs (find the single new run after the baseline)
    O->>API: GET /repos/:owner/:repo/actions/runs/:id (poll to completion)
    O-->>O: green only if every run concluded success
```

## Notes that shape the implementation

- **Nothing is installed in the target repositories.** The sweep calls the
  `workflow_dispatch` entry point that already exists, with the inputs that
  workflow already declares. That keeps one source of truth for how terraform
  runs in each repo (runner, SPN, backend, tfvars) and means there is no second
  pipeline that can drift from the real one.
- **The only target-side change is `-detailed-exitcode` plus the upload.**
  Without it a plan with changes exits `0`. The exit code is captured instead of
  failing the step, so drift stays green and only a terraform error turns the
  run red — run status keeps meaning "the pipeline worked".
- **Storage is reused, not created.** Reports go to a `drift-reports` container
  in the storage account the target already discovers (`sttfst`), created
  idempotently on first drift. No new app registration, no new secrets, no new
  role assignment; the plan step's existing OIDC session is reused for the
  upload. `azure/setup.sh` (dedicated account) is therefore optional.
- **`azresource` is the per-stack discriminator.** Each value has its own
  `ROOT_PATH=infra/<azresource>`, var-file and state key
  (`tfstate-infra-<azresource>`), so each is a separate drift target and gets
  its own report name. The 12 combinations are data in `repos.json`, not
  workflow variants.
- **Dispatch returns no run id, so runs are discovered and verified.**
  `workflow_dispatch` returns `204` with no body. With one target the sweep takes
  the single new `workflow_dispatch` run on the default branch after a
  pre-dispatch baseline; more than one candidate is a hard error
  (`Ambiguous dispatch`) rather than a guess. The `verify` job then polls every
  discovered run: any conclusion other than `success`, any run that cannot be
  identified, or any missing record fails the sweep.
- **Self-hosted runners are allowed for.** The target keeps
  `runs-on: [pda-self-hosted-linux]`; the orchestrator itself runs on
  `ubuntu-24.04` and only speaks to the GitHub API, so it needs no network path
  to Azure or to the private state storage.
- **`terraform fmt -check` runs before the plan** in the target pipeline. A
  formatting difference fails the job before plan executes and shows up as a
  failed run, not as drift — a real pipeline failure, surfaced as one.
- **Reports may contain secrets.** `terraform show -json` includes sensitive
  attribute values in plaintext. The container is private and reports should be
  treated as sensitive data.
