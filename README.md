# Terraform Drift Detection — Phase 1

Serverless, GitHub Actions only. One central repository triggers the Terraform
pipelines that already exist in your other repos, collects a JSON report when
they detect drift, and fails its own run when a triggered pipeline fails.

**Nothing is installed into the target repositories except two changes to the
plan step of a pipeline you already have.** No caller workflow, no reusable
workflow, no new app registration, no new secrets.

Start with a single target (`dev` + `containerapps`), confirm it, then add the
rest as `repos.json` entries only.

See [docs/architecture.md](docs/architecture.md) for the flow diagram.

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `repos.json` | Which repository, which existing workflow, which inputs. The only file you edit to add targets |
| `.github/workflows/drift-orchestrator.yml` | Cron + manual sweep: validate, fan out, dispatch, verify |
| `scripts/dispatch-drift-check.sh` | `workflow_dispatch` helper: preflight, retry, run discovery, clear errors |
| `scripts/await-drift-runs.sh` | Polls every dispatched run; fails the sweep if one did not finish green |
| `examples/landingzone-infra-deploy.yml` | Your deploy pipeline with the two drift changes applied — copy over the original |
| `docs/architecture.md` | Flow + sequence diagrams |
| `azure/` | **Not needed** for this design. Kept only if you later want a dedicated drift storage account instead of reusing the state account |

---

## What the sweep does

1. **Prepare** — `repos.json` is validated and flattened with `jq` into one
   matrix row per target: `{repo, ref, workflow_file, workflow_label,
   environment, dispatch_inputs}`.
2. **Dispatch** — one job per row POSTs to
   `/repos/{owner}/{repo}/actions/workflows/{file}/dispatches` on the target's
   **default branch**, with `inputs` exactly as written in `repos.json`.
   `max-parallel` comes from `defaults.max_parallel` (1–10).
3. **Target runs** — your existing pipeline does what it always does:
   checkout, `azure/login` with the landing-zone SPN, `terraform init` against
   `rg-tfstate`, then `terraform plan -detailed-exitcode`.
4. **Report** — exit code decides:

| Exit code | Meaning | Target run | Report |
| --- | --- | --- | --- |
| `0` | No drift | green | none |
| `1` | Terraform error | **red** | plan log artifact (7 days) |
| `2` | Drift detected | green | `drift-report.json` → blob storage |

5. **Verify** — the sweep polls each dispatched run. Any conclusion other than
   `success`, any run it could not identify, or any missing record fails the
   sweep. Green sweep = every plan really ran green. Time budget is
   `MAX_WAIT_SECONDS` (default 3600, override with the repository variable
   `DRIFT_VERIFY_TIMEOUT_SECONDS`).
6. **Summarise** — a final job writes the sweep table.

---

## The two changes in your repository

`examples/landingzone-infra-deploy.yml` is your file with only these applied:

**1. The plan step captures `-detailed-exitcode`.**

```yaml
- name: Terraform Plan
  if: ${{ github.event.inputs.terraformAction == 'plan' }}
  id: plan
  run: |
    set +e
    terraform plan -detailed-exitcode -out=tfplan.binary \
      -var-file=${{ github.event.inputs.environment }}/params-${{ github.event.inputs.azresource }}.tfvars \
      2>&1 | tee terraform-plan.log
    rc=${PIPESTATUS[0]}
    echo "exit_code=$rc" >> "$GITHUB_OUTPUT"
    [ "$rc" -lt 2 ]     # 0 and 2 are both fine; only 1 fails the job
  working-directory: ${{ env.ROOT_PATH }}
```

Without `-detailed-exitcode` a plan with changes exits `0`, which is why a
drift sweep of an untouched pipeline always reports "no drift".

**2. A "Publish drift report" step runs when the exit code is `2`.** It runs
`terraform show -json tfplan.binary`, drops `no-op` and `read` changes with
`jq`, wraps the rest in metadata, and uploads to:

```
<DRIFT_CONTAINER>/drift-reports/YYYY-MM-DD/<owner>__<repo>-landingzone-<azresource>-<environment>.json
# e.g. drift-reports/drift-reports/2026-11-18/acme-corp__landingzone-infra-landingzone-containerapps-dev.json
```

`DRIFT_CONTAINER` defaults to `drift-reports` and lives in the same storage
account the state backend already uses (the one found by the existing
`sttfst` query), so **no new secrets, no new app registration and no role
assignment are needed** — the pipeline already creates containers there with
`--auth-mode login`. Point reports elsewhere only if you want to: set the
repository variable `DRIFT_STORAGE_ACCOUNT`.

Report shape:

```json
{
  "metadata": {
    "repo": "acme-corp/landingzone-infra",
    "workflow": "landingzone-containerapps",
    "environment": "dev",
    "timestamp": "2026-11-18T02:04:11Z",
    "run_url": "https://github.com/acme-corp/landingzone-infra/actions/runs/123",
    "run_id": "123",
    "commit_sha": "abc123...",
    "working_directory": "/home/runner/_work/landingzone-infra/infra/containerapps"
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

## Step 1 — Orchestrator token

`GITHUB_TOKEN` cannot dispatch workflows in *other* repositories. Create a
fine-grained PAT:

- **Repository access:** the target repositories (or all repos in the org)
- **Permissions:** `Actions: Read and write` (read is used to poll run status),
  `Contents: Read`, `Metadata: Read`
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
The script treats the token as opaque, so nothing else changes.

---

## Step 2 — Copy the two changes into the target pipeline

Replace `.github/workflows/landingzone-infra-deploy.yml` in the target repo with
`examples/landingzone-infra-deploy.yml`, or apply just the two blocks above to
your copy. The rest of the file is untouched, including `terraformAction=apply`.

Then check the target repo:

- the file is on the **default branch** (`main`) — dispatch runs the version
  that exists on the ref it is given;
- `LZ_SPN_APP_ID` has a **federated credential for `refs/heads/main`**, not only
  the feature-branch subject. If not, the run fails with `AADSTS70021:
  No matching federated identity record found`. Check with
  `az ad app federated-credential list --id <app-object-id> -o table`.

---

## Step 3 — Set the first target in `repos.json`

```json
{
  "defaults": {
    "default_branch": "main",
    "max_parallel": 1
  },
  "repositories": [
    {
      "repo": "acme-corp/landingzone-infra",
      "default_branch": "main",
      "enabled": true,
      "workflows": [
        {
          "file": "landingzone-infra-deploy.yml",
          "label": "landingzone",
          "targets": [
            {
              "dispatch_inputs": {
                "environment": "dev",
                "azresource": "containerapps",
                "terraformAction": "plan"
              }
            }
          ]
        }
      ]
    }
  ]
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `repo` | yes | `owner/name` |
| `default_branch` | no | falls back to `defaults.default_branch` |
| `enabled` | no | `false` pauses the repo without deleting config |
| `workflows[].file` | yes | the workflow that **already exists** in that repo |
| `workflows[].label` | no | short name for job titles and summaries |
| `workflows[].targets[]` | yes | one matrix row per target |
| `targets[].dispatch_inputs` | yes | passed to `workflow_dispatch` verbatim; must include `environment` |
| `workflows[].disabled` | no | `true` pauses just that workflow |
| `defaults.max_parallel` | no | 1–10 concurrent dispatches |

Every key in `dispatch_inputs` must be an input that workflow declares, and
`choice` inputs only accept their listed options — otherwise dispatch returns
`422`. The keys are sent as-is, so anything the target declares (`terraformAction`,
`azresource`, a future `region`, …) works without touching this repo's scripts.

---

## Step 4 — Run it

```bash
# 1. Safe dry run: builds the matrix and prints the payload, no API calls
gh workflow run drift-orchestrator.yml -f dry_run=true

# 2. Real sweep
gh workflow run drift-orchestrator.yml
```

Or trigger the target directly, without the orchestrator, to see the report
step work on its own:

```bash
gh workflow run landingzone-infra-deploy.yml -R acme-corp/landingzone-infra \
  -f environment=dev -f azresource=containerapps -f terraformAction=plan
```

Force drift to test the happy path: change something in the portal that
Terraform manages, re-run, expect a green run and a new blob:

```bash
az storage blob list \
  --account-name <storage-account> \
  --container-name drift-reports \
  --prefix "drift-reports/$(date -u +%F)/" \
  --auth-mode login \
  -o table
```

---

## Scaling to all 12 targets

Add rows, nothing else:

```json
"targets": [
  { "dispatch_inputs": { "environment": "dev", "azresource": "containerapps", "terraformAction": "plan" } },
  { "dispatch_inputs": { "environment": "dev", "azresource": "storage",      "terraformAction": "plan" } },
  { "dispatch_inputs": { "environment": "tst", "azresource": "containerapps", "terraformAction": "plan" } }
]
```

**One prerequisite:** with more than one target per workflow, the runs must be
distinguishable. `workflow_dispatch` returns no run id, so the sweep currently
matches "the single new `workflow_dispatch` run on `main`" — with two targets
that becomes ambiguous and the dispatch job fails loudly (`Ambiguous dispatch`).
Fix it by adding the discriminator to `run-name` in the target workflow:

```yaml
run-name: >-
  ${{ github.event.inputs.environment }}-${{ github.event.inputs.azresource
  }}-Infra-${{ github.event.inputs.terraformAction }} ${{ github.ref_name }}
```

Once that is in place the sweep can tell the 12 runs apart. Keep
`defaults.max_parallel` low until you know how the shared self-hosted runner
copes.

---

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Dispatch step `404` | File name wrong in `repos.json`, or the workflow is not on `default_branch`. |
| Dispatch step `422` | A `dispatch_inputs` key is not declared by that workflow, or a `choice` value is not one of its options. |
| `AADSTS70021: No matching federated identity record found` | The SPN has no federated credential for `refs/heads/main`. Add one (or dispatch from a branch it does trust). |
| `Dispatched run not found` | Run did not appear within 180s (runner queue) or Actions is disabled. Re-run the sweep. |
| `Ambiguous dispatch` | More than one new run appeared on that workflow — see "Scaling to all 12 targets" and add the discriminator to `run-name`. |
| Target run red with `Terraform plan failed (exit 1)` | Real Terraform error — open the run and the `terraform-plan-log-*` artifact. The sweep is red too, via the verify job. |
| Target run red before the plan | `terraform fmt -check -recursive` failed, or the backend/var-file is missing. Not drift: a real pipeline failure. |
| Green target run, no blob | Exit code was `0` — no drift, nothing to upload. Check the run summary. |
| `403 AuthorizationPermissionMismatch` on upload | The SPN cannot write to the container. Confirm it has `Storage Blob Data Contributor` on that storage account (this pipeline already creates containers there, so it normally does). |
| `AuthorizationFailure` / container not found | The `sttfst` discovery query returned an empty `STORAGE_ACCOUNT_NAME`, or `DRIFT_CONTAINER` is not a valid container name (3–63 lowercase letters, digits, hyphens). |

---

## Security notes

- **No static Azure credentials.** The target pipeline keeps its existing OIDC
  (`azure/login` + federated credential); the orchestrator holds only a GitHub
  token and never touches Azure.
- **Least privilege.** The orchestrator's only permissions are Actions
  dispatch/read and repo contents read. The report write reuses the identity the
  plan already runs as.
- **Plan JSON contains sensitive values.** `terraform show -json` emits
  sensitive attributes in plaintext. The container is private, but treat it as
  sensitive and clean up old reports.
- **Workflow permissions** default to `permissions: {}` in the orchestrator;
  each job opts in to `contents: read` / `actions: read` only.
- **Pinned actions**, `persist-credentials: false` on every checkout, secrets
  never echoed.

---

## Phase 1 boundary

Included: scheduling, fan-out, dispatch of existing pipelines, run
verification, drift detection via exit code, `jq` filtering, blob storage.
Not included (Phase 2): Event Grid subscription, AI analysis, Teams
notification, historical comparison, dashboards.
