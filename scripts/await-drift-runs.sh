#!/usr/bin/env bash
# =============================================================================
# Poll every run dispatched by a drift sweep and fail the sweep when any target
# run did not finish green.
#
# `workflow_dispatch` is asynchronous: without this step a sweep would be green
# as soon as the dispatches were accepted, even if every target plan then blew
# up. This script closes that gap.
#
# Input: the JSON records written by scripts/dispatch-drift-check.sh and
# downloaded from the `drift-run-*` artifacts.
#
# Required environment:
#   GH_TOKEN            token with Actions: read on the target repositories
# Optional environment:
#   RUNS_DIR              directory of run info JSON files (default: ./runs)
#   MAX_WAIT_SECONDS      wall-clock budget for all runs (default 3600)
#   POLL_INTERVAL_SECONDS poll interval (default 20)
#   EXPECTED              number of dispatches the sweep attempted (default 0)
#   DISPATCH_RESULT       result of the dispatch job (success/failure/...)
#   GITHUB_API_URL        API base (defaults to https://api.github.com)
#
# Exit codes:
#   0 - every expected run was found and finished with conclusion "success"
#   1 - a run failed, timed out, could not be read, or was never identified
# =============================================================================
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_API_URL="${GITHUB_API_URL%/}"
RUNS_DIR="${RUNS_DIR:-./runs}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-3600}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-20}"
EXPECTED="${EXPECTED:-0}"
DISPATCH_RESULT="${DISPATCH_RESULT:-unknown}"
MAX_API_FAILURES="${MAX_API_FAILURES:-5}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

log() { printf '[verify] %s\n' "$*"; }

shopt -s nullglob
run_files=("$RUNS_DIR"/*.json)
shopt -u nullglob

if ! [[ "$MAX_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  log "MAX_WAIT_SECONDS is not an integer - using 3600"
  MAX_WAIT_SECONDS=3600
fi

declare -a R_REPO=() R_ID=() R_TARGET=() R_URL=() R_STATUS=() R_DETAIL=() R_API_FAILURES=()

add_record() {
  R_REPO+=("$1")
  R_ID+=("$2")
  R_TARGET+=("$3")
  R_URL+=("$4")
  R_STATUS+=("$5")
  R_DETAIL+=("$6")
  R_API_FAILURES+=("0")
}

for file in "${run_files[@]}"; do
  repo=$(jq -r '.repo // ""' "$file")
  run_id=$(jq -r '.run_id // 0' "$file")
  label=$(jq -r '.workflow_label // "workflow"' "$file")
  environment=$(jq -r '.environment // "?"' "$file")
  run_url=$(jq -r '.run_url // ""' "$file")
  error=$(jq -r '.error // ""' "$file")
  target="${repo}/${label}/${environment}"

  if [ -z "$repo" ] || [ "${run_id:-0}" = "0" ]; then
    add_record "$repo" 0 "$target" "$run_url" unverified "${error:-no run id was recorded for this dispatch}"
  else
    add_record "$repo" "$run_id" "$target" "$run_url" pending ""
  fi
done

total=${#R_REPO[@]}
log "verifying $total dispatched run(s); expected $EXPECTED; dispatch job: $DISPATCH_RESULT"

if [ "$total" -eq 0 ]; then
  if [ "$EXPECTED" != "0" ] && [ "$DISPATCH_RESULT" = "success" ]; then
    echo "::error title=Nothing to verify::The sweep dispatched $EXPECTED target(s) but no run information was recorded, so their results are unverified."
    exit 1
  fi
  log "no dispatched runs to verify - nothing to do"
  {
    echo
    echo "**Verification:** no dispatched runs to verify."
  } >> "$SUMMARY"
  exit 0
fi

# -----------------------------------------------------------------------------
# Poll until every run is completed or the wall clock runs out.
# -----------------------------------------------------------------------------
deadline=$(( SECONDS + MAX_WAIT_SECONDS ))

while :; do
  pending=0

  for i in "${!R_REPO[@]}"; do
    [ "${R_STATUS[i]}" = "pending" ] || continue

    json=$(gh api --method GET \
      "$GITHUB_API_URL/repos/${R_REPO[i]}/actions/runs/${R_ID[i]}" 2>/dev/null) || json=""

    if [ -z "$json" ]; then
      R_API_FAILURES[i]=$(( R_API_FAILURES[i] + 1 ))
      if [ "${R_API_FAILURES[i]}" -ge "$MAX_API_FAILURES" ]; then
        R_STATUS[i]=unverified
        R_DETAIL[i]="could not read run ${R_ID[i]} after ${MAX_API_FAILURES} attempts"
      else
        pending=1
      fi
      continue
    fi
    R_API_FAILURES[i]=0

    status=$(jq -r '.status // "unknown"' <<< "$json")
    conclusion=$(jq -r '.conclusion // ""' <<< "$json")
    url=$(jq -r '.html_url // ""' <<< "$json")
    if [ -n "$url" ]; then R_URL[i]="$url"; fi

    case "$status" in
      completed)
        if [ "$conclusion" = "success" ]; then
          R_STATUS[i]=passed
          R_DETAIL[i]="conclusion=success"
        else
          R_STATUS[i]=failed
          R_DETAIL[i]="conclusion=${conclusion:-unknown}"
        fi
        ;;
      *)
        R_DETAIL[i]="status=$status"
        pending=1
        ;;
    esac
  done

  [ "$pending" -eq 0 ] && break

  if (( SECONDS >= deadline )); then
    for i in "${!R_STATUS[@]}"; do
      if [ "${R_STATUS[i]}" = "pending" ]; then
        R_STATUS[i]=timeout
        R_DETAIL[i]="not completed within ${MAX_WAIT_SECONDS}s"
      fi
    done
    break
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done

# -----------------------------------------------------------------------------
# Report.
# -----------------------------------------------------------------------------
failures=0
{
  echo
  echo "### Target run verification"
  echo
  echo "| Target | Result | Run |"
  echo "| --- | --- | --- |"
} >> "$SUMMARY"

for i in "${!R_REPO[@]}"; do
  link="—"
  if [ -n "${R_URL[i]}" ]; then
    link="[${R_ID[i]}](${R_URL[i]})"
  fi
  {
    echo "| \`${R_TARGET[i]}\` | ${R_STATUS[i]} (${R_DETAIL[i]}) | $link |"
  } >> "$SUMMARY"

  case "${R_STATUS[i]}" in
    passed)
      log "PASS ${R_TARGET[i]} run=${R_ID[i]}"
      ;;
    *)
      failures=$(( failures + 1 ))
      log "FAIL ${R_TARGET[i]} run=${R_ID[i]}: ${R_STATUS[i]} (${R_DETAIL[i]})"
      echo "::error title=Drift check did not pass::\`${R_TARGET[i]}\` ${R_STATUS[i]} - ${R_DETAIL[i]}. ${R_URL[i]}"
      ;;
  esac
done

# Every dispatch must be accounted for, or the sweep would be silently partial.
if [ "$EXPECTED" != "0" ] && [ "$total" -lt "$EXPECTED" ]; then
  echo "::error title=Missing run verification::The sweep attempted $EXPECTED dispatch(es) but only $total run record(s) were available to verify."
  failures=$(( failures + 1 ))
fi

{
  echo
  echo "**Verification:** $(( total - failures < 0 ? 0 : total - failures ))/$total run(s) passed."
} >> "$SUMMARY"

if [ "$failures" -gt 0 ]; then
  log "$failures verification problem(s) - failing the sweep"
  exit 1
fi

log "all $total dispatched run(s) finished green"
exit 0
