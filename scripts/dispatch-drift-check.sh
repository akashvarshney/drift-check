#!/usr/bin/env bash
# =============================================================================
# Dispatch ONE drift check by triggering a target repository's EXISTING
# Terraform workflow.
#
# Nothing is installed into the target repository: the orchestrator calls the
# same `workflow_dispatch` entry point a human would use, passing only the
# inputs that workflow already declares (see targets[].dispatch_inputs in
# repos.json). The only target-side change is that the plan step captures
# `-detailed-exitcode` and uploads a report when the exit code is 2.
#
# `workflow_dispatch` returns 204 with no body, so the created run is found
# afterwards from the Actions runs API:
#   * primary  - a run whose display title contains CORRELATION_ID (only used
#                when the target workflow's `run-name` carries it)
#   * fallback - the single run that appeared after a pre-dispatch baseline
#
# The discovered run is written to $RUNNER_TEMP/run-info/<name>.json and
# uploaded as a build artifact; the `verify` job polls it to completion so a
# failed target run can never leave the sweep looking green.
#
# Required environment:
#   GH_TOKEN            fine-grained PAT / GitHub App token (Actions: write)
#   TARGET_REPO         owner/name
#   TARGET_REF          branch to run on (always the default branch)
#   WORKFLOW_FILE       the target's existing workflow file, e.g.
#                       landingzone-infra-deploy.yml
#   DISPATCH_INPUTS     JSON object of workflow_dispatch inputs, e.g.
#                       {"environment":"dev","azresource":"containerapps",
#                        "terraformAction":"plan"}
# Optional environment:
#   CORRELATION_ID         unique per dispatch; passed through as an input and
#                          used to find the run (only if the workflow declares
#                          it and stamps it into `run-name`)
#   WORKFLOW_LABEL         short label used in report names and summaries
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

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_API_URL="${GITHUB_API_URL%/}"
DRY_RUN="${DRY_RUN:-false}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
DISPATCH_INPUTS="${DISPATCH_INPUTS:-}"
CORRELATION_ID="${CORRELATION_ID:-}"
WORKFLOW_LABEL="${WORKFLOW_LABEL:-}"
ORCHESTRATOR_RUN_URL="${ORCHESTRATOR_RUN_URL:-}"
RUN_DISCOVERY_TIMEOUT="${RUN_DISCOVERY_TIMEOUT:-180}"
RUN_INFO_DIR="${RUN_INFO_DIR:-${RUNNER_TEMP:-/tmp}/run-info}"

log() { printf '[dispatch] %s\n' "$*"; }

endpoint="$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE/dispatches"
runs_endpoint="$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE/runs"

# -----------------------------------------------------------------------------
# Inputs. Every key below must be declared by the target workflow, because
# workflow_dispatch answers 422 for any input it does not know. There is no
# fallback payload: an undeclared input is a configuration mistake in
# repos.json and is reported as one.
# -----------------------------------------------------------------------------
if [ -z "$DISPATCH_INPUTS" ]; then
  echo "::error title=Missing dispatch inputs::DISPATCH_INPUTS is empty. Add targets[].dispatch_inputs to repos.json."
  exit 1
fi

if ! jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<< "$DISPATCH_INPUTS"; then
  echo "::error title=Invalid dispatch inputs::DISPATCH_INPUTS must be a non-empty JSON object of workflow_dispatch inputs."
  exit 1
fi

# The environment drives job titles, report names and the run-info record.
ENVIRONMENT=$(jq -r '.environment // "unknown"' <<< "$DISPATCH_INPUTS" | tr -d '\n')

# Blob-safe / artifact-safe identifiers for the run info file name.
repo_slug=$(printf '%s' "$TARGET_REPO" | sed -e 's|/|__|g' -e 's|[^A-Za-z0-9._-]|_|g')
label="${WORKFLOW_LABEL:-${WORKFLOW_FILE%.yml}}"
label="${label%.yaml}"
label_slug=$(printf '%s' "$label" | sed -e 's|[^A-Za-z0-9._-]|_|g')
env_slug=$(printf '%s' "$ENVIRONMENT" | sed -e 's|[^A-Za-z0-9._-]|_|g')
run_info_file="$RUN_INFO_DIR/drift-run-${repo_slug}-${label_slug}-${env_slug}.json"

build_payload() {
  jq -n \
    --arg ref "$TARGET_REF" \
    --argjson inputs "$DISPATCH_INPUTS" \
    --arg correlation_id "$CORRELATION_ID" \
    '{
       ref: $ref,
       inputs: ($inputs
                + (if $correlation_id == "" then {} else {correlation_id: $correlation_id} end))
     }'
}

# -----------------------------------------------------------------------------
# Preflight: does the workflow exist and is Actions usable on this repo?
# Gives a far clearer message than the 404/422 returned by dispatch.
# -----------------------------------------------------------------------------
preflight() {
  local err rc
  set +e
  err=$(gh api "$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  case "$err" in
    *"HTTP 404"*)
      echo "::error title=Workflow not found::\`$WORKFLOW_FILE\` does not exist on ref \`$TARGET_REF\` in \`$TARGET_REPO\`. Check workflows[].file and default_branch in repos.json."
      ;;
    *"HTTP 403"*)
      echo "::error title=Missing permission::ORCHESTRATOR_TOKEN cannot read Actions in \`$TARGET_REPO\`. Grant the token Actions: read/write on that repository."
      ;;
    *)
      echo "::error title=Preflight failed::Unable to inspect \`$TARGET_REPO\`. $err"
      ;;
  esac
  return 1
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

# Echo the run object (JSON) for the dispatch, or return 1 after the timeout
# (2 when several new runs appeared and none could be identified).
discover_run() {
  local deadline=$(( SECONDS + RUN_DISCOVERY_TIMEOUT ))
  local runs match count

  while :; do
    runs=$(list_recent_runs)

    if [ -n "$CORRELATION_ID" ]; then
      match=$(jq -c --arg correlation "$CORRELATION_ID" \
        '[.[] | select((.display_title // "") | contains($correlation))]
         | sort_by(.id) | last // empty' <<< "$runs")
    else
      match=$(jq -c --arg not_before "$not_before" --argjson baseline "$baseline_run_id" \
        '[.[] | select(.id > $baseline) | select((.created_at // "") >= $not_before)]
         | sort_by(.id)' <<< "$runs")
      count=$(jq 'length' <<< "$match")
      if [ "$count" -gt 1 ]; then
        echo "::error title=Ambiguous dispatch::$count new \`$WORKFLOW_FILE\` runs appeared on \`$TARGET_REPO@$TARGET_REF\`, so the dispatched run cannot be identified. Sweep one target at a time per workflow, or add the environment/azresource to that workflow's \`run-name\` so runs are distinguishable." >&2
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
    --argjson dispatch_inputs "$DISPATCH_INPUTS" \
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
       dispatch_inputs: $dispatch_inputs,
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
log "target=$TARGET_REPO ref=$TARGET_REF workflow=$WORKFLOW_FILE inputs=$DISPATCH_INPUTS"

payload=$(build_payload)

if [ "$DRY_RUN" = "true" ]; then
  log "DRY RUN - not calling the GitHub API"
  preflight || true
  log "POST $endpoint"
  printf '%s\n' "$payload" | jq .
  exit 0
fi

preflight || exit 1

# Fallback correlation needs a "before" snapshot: any run newer than this is a
# candidate for the dispatch below.
baseline_run_id=$(list_recent_runs | jq 'map(.id) | max // 0')
not_before=$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)
log "baseline run id for $WORKFLOW_FILE@$TARGET_REF: $baseline_run_id"

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
      echo "::error title=Dispatch 404::\`$WORKFLOW_FILE\` on ref \`$TARGET_REF\` was not found in \`$TARGET_REPO\`. Check default_branch in repos.json and that the workflow exists on that branch."
      write_run_info "" "" "dispatch failed: workflow not found on ref $TARGET_REF (HTTP 404)"
      exit 1
      ;;
    *"HTTP 422"*)
      echo "::error title=Dispatch 422::Ref or inputs rejected for \`$TARGET_REPO\`. Every key in targets[].dispatch_inputs must be a \`workflow_dispatch\` input declared by \`$WORKFLOW_FILE\`, and the value must match its type (choice inputs only accept their listed options). Sent: $DISPATCH_INPUTS. API said: $err"
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
    echo "::error title=Dispatched run not found::Could not identify the run created for \`$TARGET_REPO\` / \`$WORKFLOW_FILE\`. Check that the workflow is enabled and that its \`run-name\` is stable."
  fi
  write_run_info "" "" "$reason"
  exit 1
fi

{
  echo "#### Dispatched"
  echo
  echo "- Repository: \`$TARGET_REPO\` @ \`$TARGET_REF\`"
  echo "- Workflow: \`$WORKFLOW_FILE\`"
  echo "- Inputs: \`$DISPATCH_INPUTS\`"
  echo "- Run: [$run_id]($run_url)"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

log "dispatched run id=$run_id url=$run_url"
