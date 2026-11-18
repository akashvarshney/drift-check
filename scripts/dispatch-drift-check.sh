#!/usr/bin/env bash
# =============================================================================
# Dispatch a single Phase 1 drift check in a target repository, then find the
# run the dispatch created.
#
# `workflow_dispatch` returns 204 with no body, so the run id is discovered
# from the Actions runs API:
#   * primary  - match the unique correlation id the orchestrator injects into
#                the caller's `run-name` (see examples/target-repo-caller.yml)
#   * fallback - for callers that do not declare `correlation_id`, take the
#                single run that appeared after a pre-dispatch baseline
#
# The discovered run is written to $RUNNER_TEMP/run-info/<name>.json and
# uploaded as a build artifact; the `verify` job polls it to completion so a
# failed target run can never leave the sweep looking green.
#
# Required environment:
#   GH_TOKEN            fine-grained PAT / GitHub App token (Actions: write)
#   TARGET_REPO         owner/name
#   TARGET_REF          branch to run on (always the default branch)
#   WORKFLOW_FILE       workflow file name, e.g. terraform-drift-check.yml
#   ENVIRONMENT         dev | staging | prod | ...
# Optional environment:
#   BLOB_CONTAINER         report container (from repos.json defaults)
#   CORRELATION_ID         unique per dispatch; delivered to the caller run name
#   WORKFLOW_LABEL         short label used in blob names
#   WORKING_DIRECTORY      terraform directory, may contain {environment}
#   TERRAFORM_VERSION      terraform version to install
#   ORCHESTRATOR_RUN_URL   link back to the sweep
#   DRY_RUN                "true" to log the payload without calling the API
#   GITHUB_API_URL         API base (defaults to https://api.github.com)
#   MAX_ATTEMPTS           dispatch attempts on 403/429/5xx (default 3)
#   RUN_DISCOVERY_TIMEOUT  seconds to wait for the run to appear (default 180)
#   RUN_INFO_DIR           where to write run info (default $RUNNER_TEMP/run-info)
# =============================================================================
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${TARGET_REPO:?TARGET_REPO is required}"
: "${TARGET_REF:?TARGET_REF is required}"
: "${WORKFLOW_FILE:?WORKFLOW_FILE is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_API_URL="${GITHUB_API_URL%/}"
DRY_RUN="${DRY_RUN:-false}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
BLOB_CONTAINER="${BLOB_CONTAINER:-drift-reports}"
CORRELATION_ID="${CORRELATION_ID:-}"
WORKFLOW_LABEL="${WORKFLOW_LABEL:-}"
WORKING_DIRECTORY="${WORKING_DIRECTORY:-.}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"
ORCHESTRATOR_RUN_URL="${ORCHESTRATOR_RUN_URL:-}"
RUN_DISCOVERY_TIMEOUT="${RUN_DISCOVERY_TIMEOUT:-180}"
RUN_INFO_DIR="${RUN_INFO_DIR:-${RUNNER_TEMP:-/tmp}/run-info}"

log() { printf '[dispatch] %s\n' "$*"; }

endpoint="$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE/dispatches"
runs_endpoint="$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE/runs"

# Azure container names: 3-63 chars, lowercase letters, digits and hyphens,
# starting and ending alphanumeric.
if ! [[ "$BLOB_CONTAINER" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  echo "::error title=Invalid blob container::'$BLOB_CONTAINER' is not a valid Azure container name. Fix defaults.blob_container (or the workflow override) in repos.json."
  exit 1
fi

# Blob-safe / artifact-safe identifiers for the run info file name.
repo_slug=$(printf '%s' "$TARGET_REPO" | sed -e 's|/|__|g' -e 's|[^A-Za-z0-9._-]|_|g')
label="${WORKFLOW_LABEL:-${WORKFLOW_FILE%.yml}}"
label="${label%.yaml}"
label_slug=$(printf '%s' "$label" | sed -e 's|[^A-Za-z0-9._-]|_|g')
env_slug=$(printf '%s' "$ENVIRONMENT" | sed -e 's|[^A-Za-z0-9._-]|_|g')
run_info_file="$RUN_INFO_DIR/drift-run-${repo_slug}-${label_slug}-${env_slug}.json"

# -----------------------------------------------------------------------------
# Payloads. Every input below must be declared by the target caller workflow;
# workflow_dispatch returns 422 for unknown inputs.
# -----------------------------------------------------------------------------
build_payload() {
  jq -n \
    --arg ref "$TARGET_REF" \
    --arg environment "$ENVIRONMENT" \
    --arg working_directory "$WORKING_DIRECTORY" \
    --arg terraform_version "$TERRAFORM_VERSION" \
    --arg workflow_label "$WORKFLOW_LABEL" \
    --arg orchestrator_run_url "$ORCHESTRATOR_RUN_URL" \
    --arg blob_container "$BLOB_CONTAINER" \
    --arg correlation_id "$CORRELATION_ID" \
    '{
       ref: $ref,
       inputs: ({
         environment: $environment,
         drift_check_only: "true",
         working_directory: $working_directory,
         terraform_version: $terraform_version,
         workflow_label: $workflow_label,
         orchestrator_run_url: $orchestrator_run_url,
         blob_container: $blob_container
       }
       + (if $correlation_id == "" then {} else {correlation_id: $correlation_id} end))
     }'
}

# Minimal payload for callers that do not declare the optional inputs
# (sending an undeclared input makes workflow_dispatch return 422).
build_minimal_payload() {
  jq -n \
    --arg ref "$TARGET_REF" \
    --arg environment "$ENVIRONMENT" \
    '{
       ref: $ref,
       inputs: {
         environment: $environment,
         drift_check_only: "true"
       }
     }'
}

# -----------------------------------------------------------------------------
# Preflight: does the workflow exist and is Actions usable on this repo?
# Gives a far clearer message than the 404/422 returned by dispatch.
# -----------------------------------------------------------------------------
preflight() {
  local err
  set +e
  err=$(gh api "$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE" 2>&1 >/dev/null)
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  case "$err" in
    *"HTTP 404"*)
      echo "::error title=Workflow not found::\`$WORKFLOW_FILE\` does not exist in \`$TARGET_REPO\`. Add examples/target-repo-caller.yml to that repository."
      ;;
    *"HTTP 403"*)
      echo "::error title=Missing permission::ORCHESTRATOR_TOKEN cannot read Actions in \`$TARGET_REPO\`. Grant the token Actions: read/write on that repository."
      ;;
    *)
      echo "::error title=Preflight failed::Unable to inspect \`$TARGET_REPO\`. $err"
      ;;
  esac
  exit 1
}

# -----------------------------------------------------------------------------
# Run discovery.
# -----------------------------------------------------------------------------

# Recent workflow_dispatch runs for the target ref, newest first. Never fatal:
# a transient API error yields an empty list so the caller can retry.
list_recent_runs() {
  gh api --method GET "$runs_endpoint" \
    -f event=workflow_dispatch \
    -f branch="$TARGET_REF" \
    -f per_page=50 \
    --jq '[.workflow_runs[]? | {id, display_title, created_at, html_url}]' 2>/dev/null \
    || printf '[]'
}

# Echo the run object (JSON) for the dispatch, or return 1 after the timeout.
discover_run() {
  local deadline=$(( SECONDS + RUN_DISCOVERY_TIMEOUT ))
  local runs match count

  while :; do
    runs=$(list_recent_runs)

    if [ "$correlation_delivered" = "true" ] && [ -n "$CORRELATION_ID" ]; then
      match=$(jq -c --arg correlation "$CORRELATION_ID" \
        '[.[] | select((.display_title // "") | contains($correlation))]
         | sort_by(.id) | last // empty' <<< "$runs")
    else
      match=$(jq -c --arg not_before "$not_before" --argjson baseline "$baseline_run_id" \
        '[.[] | select(.id > $baseline) | select((.created_at // "") >= $not_before)]
         | sort_by(.id)' <<< "$runs")
      count=$(jq 'length' <<< "$match")
      if [ "$count" -gt 1 ]; then
        echo "::error title=Ambiguous dispatch::$count new \`$WORKFLOW_FILE\` runs appeared on \`$TARGET_REPO@$TARGET_REF\`, so the dispatched run cannot be identified. Update the caller workflow to declare the \`correlation_id\` input and set \`run-name\` (see examples/target-repo-caller.yml)." >&2
        return 2
      fi
      match=$(jq -c '.[0] // empty' <<< "$match")
    fi

    if [ -n "$match" ] && [ "$match" != "null" ]; then
      printf '%s' "$match"
      return 0
    fi

    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 5
  done
}

# Persist what the verify job needs. `error` is non-empty when the run could not
# be identified; verify then reports that target as unverified (never green).
write_run_info() {
  local run_id="$1" run_url="$2" error="${3:-}"
  mkdir -p "$RUN_INFO_DIR"
  jq -n \
    --arg repo "$TARGET_REPO" \
    --arg ref "$TARGET_REF" \
    --arg workflow_file "$WORKFLOW_FILE" \
    --arg workflow_label "$label" \
    --arg environment "$ENVIRONMENT" \
    --arg run_id "$run_id" \
    --arg run_url "$run_url" \
    --arg correlation_id "$CORRELATION_ID" \
    --arg orchestrator_run_url "$ORCHESTRATOR_RUN_URL" \
    --arg dispatched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg error "$error" \
    '{
       repo: $repo,
       ref: $ref,
       workflow_file: $workflow_file,
       workflow_label: $workflow_label,
       environment: $environment,
       run_id: ($run_id | tonumber? // 0),
       run_url: $run_url,
       correlation_id: $correlation_id,
       orchestrator_run_url: $orchestrator_run_url,
       dispatched_at: $dispatched_at,
       error: $error
     }' > "$run_info_file"
  log "run info written to $run_info_file"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
log "target=$TARGET_REPO ref=$TARGET_REF workflow=$WORKFLOW_FILE environment=$ENVIRONMENT container=$BLOB_CONTAINER"

payload=$(build_payload)

if [ "$DRY_RUN" = "true" ]; then
  log "DRY RUN - not calling the GitHub API"
  preflight || true
  log "POST $endpoint"
  printf '%s\n' "$payload" | jq .
  exit 0
fi

preflight

# Fallback correlation needs a "before" snapshot: any run newer than this is a
# candidate for the dispatch below.
baseline_run_id=$(list_recent_runs | jq 'map(.id) | max // 0')
not_before=$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)
log "baseline run id for $WORKFLOW_FILE@$TARGET_REF: $baseline_run_id"

# False when the 422 fallback path was used: the caller then never received the
# correlation id, so discovery must fall back to the baseline heuristic.
correlation_delivered=true

attempt=1
while :; do
  log "attempt $attempt/$MAX_ATTEMPTS: POST $endpoint"

  set +e
  err=$(printf '%s' "$payload" | gh api --method POST "$endpoint" --input - 2>&1 >/dev/null)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    log "dispatched successfully"
    break
  fi

  case "$err" in
    *"HTTP 404"*)
      echo "::error title=Dispatch 404::\`$WORKFLOW_FILE\` on ref \`$TARGET_REF\` was not found in \`$TARGET_REPO\`. Check the branch name in repos.json and that the workflow exists on that branch."
      write_run_info "" "" "dispatch failed: workflow not found on ref $TARGET_REF (HTTP 404)"
      exit 1
      ;;
    *"HTTP 422"*)
      log "422 - retrying once with the minimal input set"
      set +e
      err2=$(printf '%s' "$(build_minimal_payload)" | gh api --method POST "$endpoint" --input - 2>&1 >/dev/null)
      rc2=$?
      set -e
      if [ "$rc2" -eq 0 ]; then
        log "dispatched with minimal inputs - update the caller workflow to declare all inputs"
        correlation_delivered=false
        break
      fi
      echo "::error title=Dispatch 422::Ref or inputs rejected for \`$TARGET_REPO\`. Ensure the workflow declares the workflow_dispatch inputs and is enabled. $err2"
      write_run_info "" "" "dispatch failed: inputs rejected (HTTP 422)"
      exit 1
      ;;
    *"HTTP 401"*)
      echo "::error title=Dispatch 401::ORCHESTRATOR_TOKEN is invalid or expired."
      exit 1
      ;;
    *"HTTP 403"*|*"HTTP 429"*|*"HTTP 5"*)
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "::error title=Dispatch failed::Gave up after $MAX_ATTEMPTS attempts. Last error: $err"
        write_run_info "" "" "dispatch failed after $MAX_ATTEMPTS attempts"
        exit 1
      fi
      # Honour Retry-After when GitHub provides it, otherwise back off.
      sleep_for=$(printf '%s' "$err" | sed -n 's/.*[Rr]etry-[Aa]fter:[[:space:]]*\([0-9]\{1,4\}\).*/\1/p' | head -n1)
      if [ -z "$sleep_for" ]; then
        sleep_for=$(( attempt * 15 ))
      fi
      log "rate limited or transient error - sleeping ${sleep_for}s"
      sleep "$sleep_for"
      attempt=$(( attempt + 1 ))
      ;;
    *)
      echo "::error title=Dispatch failed::Unexpected error from the GitHub API. $err"
      write_run_info "" "" "dispatch failed: unexpected API error"
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Correlate: locate the run this dispatch created so `verify` can watch it.
# -----------------------------------------------------------------------------
log "waiting up to ${RUN_DISCOVERY_TIMEOUT}s for the dispatched run to appear"

run_json=""
if run_json=$(discover_run); then
  run_id=$(jq -r '.id' <<< "$run_json")
  run_url=$(jq -r '.html_url // ""' <<< "$run_json")
  write_run_info "$run_id" "$run_url" ""
else
  rc=$?
  reason="the dispatched run did not appear within ${RUN_DISCOVERY_TIMEOUT}s"
  if [ "$rc" -ne 2 ]; then
    echo "::error title=Dispatched run not found::Could not identify the run created for \`$TARGET_REPO\` / \`$WORKFLOW_FILE\` / \`$ENVIRONMENT\`. Ensure the caller workflow declares the \`correlation_id\` input and sets \`run-name\` (see examples/target-repo-caller.yml)."
  fi
  write_run_info "" "" "$reason"
  exit 1
fi

{
  echo "#### Dispatched"
  echo
  echo "- Repository: \`$TARGET_REPO\` @ \`$TARGET_REF\`"
  echo "- Workflow: \`$WORKFLOW_FILE\`"
  echo "- Environment: \`$ENVIRONMENT\`"
  echo "- Report container: \`$BLOB_CONTAINER\`"
  echo "- Run: [$run_id]($run_url)"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

log "dispatched run id=$run_id url=$run_url"
