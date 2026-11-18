#!/usr/bin/env bash
# =============================================================================
# Dispatch a single Phase 1 drift check in a target repository.
#
# The GitHub REST API `workflow_dispatch` endpoint returns 204 with no body, so
# there is no run id to hand back. Traceability comes from the target run
# itself, which builds its run_url from its own context and stamps it into the
# drift report metadata.
#
# Required environment:
#   GH_TOKEN            fine-grained PAT / GitHub App token (Actions: write)
#   TARGET_REPO         owner/name
#   TARGET_REF          branch to run on (always the default branch)
#   WORKFLOW_FILE       workflow file name, e.g. terraform-drift-check.yml
#   ENVIRONMENT         dev | staging | prod | ...
# Optional environment:
#   WORKFLOW_LABEL      short label used in blob names
#   WORKING_DIRECTORY   terraform directory, may contain {environment}
#   TERRAFORM_VERSION   terraform version to install
#   ORCHESTRATOR_RUN_URL  link back to the sweep
#   DRY_RUN             "true" to log the payload without calling the API
#   GITHUB_API_URL      API base (defaults to https://api.github.com)
#   MAX_ATTEMPTS        dispatch attempts on 403/429/5xx (default 3)
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
WORKFLOW_LABEL="${WORKFLOW_LABEL:-}"
WORKING_DIRECTORY="${WORKING_DIRECTORY:-.}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"
ORCHESTRATOR_RUN_URL="${ORCHESTRATOR_RUN_URL:-}"

log() { printf '[dispatch] %s\n' "$*"; }

endpoint="$GITHUB_API_URL/repos/$TARGET_REPO/actions/workflows/$WORKFLOW_FILE/dispatches"

# Full payload matching examples/target-repo-caller.yml.
build_payload() {
  jq -n \
    --arg ref "$TARGET_REF" \
    --arg environment "$ENVIRONMENT" \
    --arg working_directory "$WORKING_DIRECTORY" \
    --arg terraform_version "$TERRAFORM_VERSION" \
    --arg workflow_label "$WORKFLOW_LABEL" \
    --arg orchestrator_run_url "$ORCHESTRATOR_RUN_URL" \
    '{
       ref: $ref,
       inputs: {
         environment: $environment,
         drift_check_only: "true",
         working_directory: $working_directory,
         terraform_version: $terraform_version,
         workflow_label: $workflow_label,
         orchestrator_run_url: $orchestrator_run_url
       }
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

log "target=$TARGET_REPO ref=$TARGET_REF workflow=$WORKFLOW_FILE environment=$ENVIRONMENT"

payload=$(build_payload)

if [ "$DRY_RUN" = "true" ]; then
  log "DRY RUN - not calling the GitHub API"
  preflight || true
  log "POST $endpoint"
  printf '%s\n' "$payload" | jq .
  exit 0
fi

preflight

attempt=1
while :; do
  log "attempt $attempt/$MAX_ATTEMPTS: POST $endpoint"

  set +e
  err=$(printf '%s' "$payload" | gh api --method POST "$endpoint" --input - 2>&1 >/dev/null)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    log "dispatched successfully"
    {
      echo "#### Dispatched"
      echo
      echo "- Repository: \`$TARGET_REPO\` @ \`$TARGET_REF\`"
      echo "- Workflow: \`$WORKFLOW_FILE\`"
      echo "- Environment: \`$ENVIRONMENT\`"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 0
  fi

  case "$err" in
    *"HTTP 404"*)
      echo "::error title=Dispatch 404::\`$WORKFLOW_FILE\` on ref \`$TARGET_REF\` was not found in \`$TARGET_REPO\`. Check the branch name in repos.json and that the workflow exists on that branch."
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
        exit 0
      fi
      echo "::error title=Dispatch 422::Ref or inputs rejected for \`$TARGET_REPO\`. Ensure the workflow declares the workflow_dispatch inputs and is enabled. $err2"
      exit 1
      ;;
    *"HTTP 401"*)
      echo "::error title=Dispatch 401::ORCHESTRATOR_TOKEN is invalid or expired."
      exit 1
      ;;
    *"HTTP 403"*|*"HTTP 429"*|*"HTTP 5"*)
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "::error title=Dispatch failed::Gave up after $MAX_ATTEMPTS attempts. Last error: $err"
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
      exit 1
      ;;
  esac
done
