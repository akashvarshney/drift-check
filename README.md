# Terraform Drift Detection — Phase 1

Serverless, GitHub Actions only. No containers to run, no Azure Automation
Account, no self-hosted infrastructure.

A daily cron (or a manual run) sweeps every `(repository x workflow x environment)`
combination listed in `repos.json`, triggers each target repository's Terraform
pipeline with `workflow_dispatch`, runs `terraform plan -detailed-exitcode`, and
— when drift is detected — uploads a `jq`-filtered JSON report to Azure Blob
Storage over passwordless OIDC.

**Phase 1 ends when the report is in the container.** AI analysis and Teams
notifications are Phase 2.

See [docs/architecture.md](docs/architecture.md) for the Mermaid diagrams.

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `repos.json` | Central inventory: repositories, workflows, environments, defaults |
| `.github/workflows/drift-orchestrator.yml` | Cron + manual sweep; builds the matrix and dispatches |
| `.github/workflows/reusable-drift-check.yml` | All drift logic: plan, filter, upload (called by targets) |
| `scripts/dispatch-drift-check.sh` | REST `workflow_dispatch` helper: preflight, retry, clear errors |
| `examples/target-repo-caller.yml` | Copy into each Terraform repo as `.github/workflows/terraform-drift-check.yml` |
| `examples/standalone-drift-job.yml` | Self-contained fallback when cross-repo reuse is not possible |
| `azure/setup.sh` | Azure CLI bootstrap (storage, container, app registration, federation, RBAC) |
| `azure/terraform/` | Same resources as code |
| `docs/architecture.md` | Mermaid flow + OIDC sequence diagrams |

---

## How it works

1. **Trigger** — `schedule` (02:00 UTC daily) or `workflow_dispatch` with an
   optional `repository_filter` regex and `dry_run` toggle.
2. **Prepare** — `repos.json` is validated and flattened with `jq` into one
   matrix row per environment: `{repo, ref, workflow_file, workflow_label,
   environment, working_directory, terraform_version}`.
3. **Dispatch** — one job per row, `max-parallel` from `defaults.max_parallel`
   (clamped to 1–10), `fail-fast: false`. Each job preflights the workflow file,
   then `POST`s to the dispatches endpoint on the **default branch**.
4. **Drift check** — the target caller invokes the reusable workflow, which logs
   in to Azure with OIDC, runs `terraform init` and
   `terraform plan -detailed-exitcode -out=tfplan.binary`.
5. **Branch** — exit code decides what happens:

| Exit code | Meaning | Orchestrator/target result | Upload |
| --- | --- | --- | --- |
| `0` | No drift | green | none |
| `1` | Terraform error | **red** (alerting) | plan log artifact (7 days) |
| `2` | Drift detected | green | `drift-report.json` → Blob Storage |

6. **Report** — `terraform show -json tfplan.binary` → `jq` drops `no-op` and
   `read` actions, keeps every real change, wraps it with metadata.

Blob path:

```
drift-reports/YYYY-MM-DD/<owner>__<repo>-<workflow_label>-<environment>.json
# e.g. drift-reports/2026-11-18/acme-corp__infra-network-network-prod.json
```

Report shape:

```json
{
  "metadata": {
    "repo": "acme-corp/infra-network",
    "workflow": "network",
    "environment": "prod",
    "timestamp": "2026-11-18T02:04:11Z",
    "run_url": "https://github.com/acme-corp/infra-network/actions/runs/123",
    "run_id": "123",
    "run_attempt": "1",
    "commit_sha": "abc123...",
    "working_directory": "environments/prod",
    "orchestrator_run_url": "https://github.com/acme-corp/drift-check/actions/runs/456",
    "detected_by": "terraform-drift-detection/phase-1"
  },
  "summary": {
    "resource_changes_total": 42,
    "drifted_resources": 2,
    "out_of_band_drift": 0
  },
  "resource_changes": [ ... ],
  "resource_drift": [ ... ]
}
```

---

## Prerequisites

- Azure subscription where you can create a storage account and an app registration.
- `az` CLI logged in, `gh` CLI logged in, `jq` (for `azure/setup.sh`).
- Terraform **≥ 1.6** locally only if you plan to run `terraform validate`.
- Each target repository already has working Terraform pipelines (state backend,
  provider credentials). This repo does not create them.

---

## Step 1 — Azure (storage, federation, RBAC)

### Option A: CLI (recommended for the first run)

```bash
az login
gh auth login

# Optional overrides:
#   SUBSCRIPTION_ID, LOCATION, RESOURCE_GROUP, STORAGE_ACCOUNT, CONTAINER_NAME,
#   APP_NAME, RETENTION_DAYS, SUBJECT_FORMAT=auto|mutable|immutable
./azure/setup.sh
```

The script is idempotent and creates:

- storage account — public blob access **off**, shared key access **off**, TLS 1.2
- `drift-reports` container (private)
- blob versioning + a lifecycle rule that deletes reports after `RETENTION_DAYS` (90)
- Entra app registration + service principal
- **one federated credential per enabled repo/branch** in `repos.json`
  (auto-detects GitHub's immutable subject format)
- `Storage Blob Data Contributor` **scoped to the container only**

It prints the four values you need for GitHub secrets.

### Option B: Terraform

```bash
cd azure/terraform
cp terraform.tfvars.example terraform.tfvars   # set storage_account_name + repos
terraform init
terraform apply
terraform output
```

Keep `github_repositories` in step with `repos.json`. For repositories on the
immutable subject format, set `subject` explicitly per entry.

---

## Step 2 — GitHub org secrets

Organization → Settings → Secrets and variables → Actions → **New organization secret**:

| Secret | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | app registration client (application) ID |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | subscription ID |
| `AZURE_STORAGE_ACCOUNT` | storage account name |

Set **Repository access → All repositories** so each target repo resolves them
through `secrets: inherit`.

---

## Step 3 — Orchestrator token

`GITHUB_TOKEN` cannot dispatch workflows in *other* repositories. Create a
fine-grained PAT:

- **Repository access:** the target repositories (or all repos in the org)
- **Permissions:** `Actions: Read and write`, `Contents: Read`, `Metadata: Read`
- **Expiry:** 90 days or less, and calendar a rotation

Store it in **this** repository as the secret `ORCHESTRATOR_TOKEN`.

GitHub App alternative:

```yaml
- uses: actions/create-github-app-token@v1
  id: app-token
  with:
    app-id: ${{ vars.ORCHESTRATOR_APP_ID }}
    private-key: ${{ secrets.ORCHESTRATOR_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
```

Then set `GH_TOKEN: ${{ steps.app-token.outputs.token }}` on the dispatch step.

---

## Step 4 — Describe the fleet in `repos.json`

```json
{
  "defaults": {
    "default_branch": "main",
    "terraform_version": "1.9.8",
    "max_parallel": 5,
    "blob_container": "drift-reports"
  },
  "repositories": [
    {
      "repo": "acme-corp/infra-network",
      "default_branch": "main",
      "enabled": true,
      "workflows": [
        {
          "file": "terraform-drift-check.yml",
          "label": "network",
          "working_directory": "environments/{environment}",
          "environments": ["dev", "staging", "prod"]
        }
      ]
    }
  ]
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `repo` | yes | `owner/name` |
| `default_branch` | no | falls back to `defaults.default_branch`; use `master` where needed |
| `enabled` | no | `false` pauses the repo without deleting config |
| `workflows[].file` | yes | the **caller** file name in that repo, on the default branch |
| `workflows[].label` | no | short name used in job titles and blob names |
| `workflows[].working_directory` | no | Terraform dir; `{environment}` is substituted at run time |
| `workflows[].terraform_version` | no | falls back to `defaults.terraform_version` |
| `workflows[].environments` | yes | each becomes one matrix row |
| `workflows[].disabled` | no | `true` pauses just that workflow |

Everything is optional except `repo`, `workflows[].file` and
`workflows[].environments`. Adding a repo or environment is a config change —
no workflow edits.

---

## Step 5 — Add the caller to every target repository

Copy `examples/target-repo-caller.yml` to
`.github/workflows/terraform-drift-check.yml` on the repo's default branch and
change the `uses:` line to your orchestrator repo:

```yaml
uses: acme-corp/drift-check/.github/workflows/reusable-drift-check.yml@main
```

Requirements:

- must live on the **default branch** (dispatch targets that ref);
- must declare **every** `workflow_dispatch` input shown in the template, or
  dispatch returns `422` (the helper retries once with a minimal payload and
  warns);
- the reusable workflow must be reachable — for private repos, allow access under
  the orchestrator repo's Settings → Actions → General → Access.

If cross-repo reuse is not possible, use
`examples/standalone-drift-job.yml` instead. It integrates the same drift branch
into an existing plan/apply pipeline: `drift_check_only: true` skips apply, runs
the detailed-exitcode plan, filters and uploads; `false` behaves exactly as today.

---

## Step 6 — Run it

```bash
# 1. Safe dry run: builds the matrix and logs payloads, no API calls
gh workflow run drift-orchestrator.yml -f dry_run=true

# 2. Real sweep, all repos
gh workflow run drift-orchestrator.yml

# 3. One repository only
gh workflow run drift-orchestrator.yml -f repository_filter='^acme-corp/infra-network$'
```

Then verify a report landed:

```bash
az storage blob list \
  --account-name <storage-account> \
  --container-name drift-reports \
  --prefix "drift-reports/$(date -u +%F)/" \
  --auth-mode login \
  -o table
```

End-to-end smoke test on a single repo, without the orchestrator:

```bash
gh workflow run terraform-drift-check.yml -R acme-corp/infra-network \
  -f environment=dev -f drift_check_only=true
```

Force drift to test the happy path: change something in the portal that
Terraform manages, re-run, and expect a green target run plus a new blob.

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `AADSTS70021: No matching federated identity record found` | `sub` mismatch. Check the branch in `repos.json`, and whether the repo uses the immutable subject format (`repo:owner@id/repo@id:ref:refs/heads/...`). Inspect with `az ad app federated-credential list --id <app-object-id> -o table`. |
| `AADSTS700016` / invalid client | `AZURE_CLIENT_ID` is the object ID instead of the application (client) ID. |
| `403 AuthorizationPermissionMismatch` on upload | RBAC missing or still propagating. Confirm `Storage Blob Data Contributor` at **container** scope; wait a few minutes after assignment. |
| Dispatch step: `404` | Caller file missing on the default branch, or the file name in `repos.json` is wrong. |
| Dispatch step: `422` | The caller does not declare an input the orchestrator sends, or Actions is disabled on the repo. |
| `Matrix vector ... does not contain any values` | Should be impossible (guarded by the `count` output); if it appears, every repo was filtered out or disabled. |
| Target run red with `Terraform plan failed (exit 1)` | Real Terraform error — download the `terraform-plan-log-<env>` artifact. |
| Green target run, no blob | Exit code was `0` (no drift) — check the run's step summary. |
| Warning `exit code 2 without resource drift` | The plan reported changes but only outputs / data sources changed; the report is uploaded with null/empty arrays. |

---

## Security notes

- **No static Azure credentials.** OIDC only; the storage account rejects shared
  key access entirely, so `--auth-mode login` is the only way in.
- **Least privilege.** `Storage Blob Data Contributor` at container scope; the
  orchestrator's only extra permission is Actions dispatch.
- **Plan JSON contains sensitive values.** `terraform show -json` emits
  sensitive attributes in plaintext. The container is private, blobs expire
  after 90 days, and versioning is enabled. Treat the container as sensitive and
  restrict data-plane access.
- **Workflow permissions** default to `permissions: {}` in the orchestrator;
  jobs opt in to `contents: read`, and only the target job needs `id-token: write`.
- **Pinned actions.** Actions are pinned to major tags (`@v4`, `@v3`, `@v2`), the
  usual baseline. For stricter supply-chain control, pin to commit SHAs.
- **Secrets never touch logs.** Azure identifiers are not secrets, but the
  storage account name is only ever read from secrets at runtime.
- `persist-credentials: false` on every checkout.

---

## Phase 1 boundary

Included: scheduling, fan-out, dispatch, drift detection, filtering, storage.
Not included (Phase 2): Event Grid subscription, AI analysis, Teams
notification, historical comparison, drift dashboards.
