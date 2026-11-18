#!/usr/bin/env bash
# =============================================================================
# Phase 1 - Azure bootstrap for automated Terraform drift detection.
#
# Creates, idempotently (safe to re-run):
#   1. resource group
#   2. storage account  - public blob access OFF, shared key access OFF, TLS 1.2
#   3. drift-reports container (private)
#   4. blob versioning + a retention lifecycle rule
#   5. Entra app registration + service principal
#   6. one federated credential per (repository, default branch) in repos.json
#   7. Storage Blob Data Contributor scoped to the CONTAINER only
#
# Everything is passwordless: GitHub Actions authenticates with an OIDC token,
# Entra exchanges it for a storage token. No storage keys, no client secrets.
#
# Prerequisites: az (logged in), gh (logged in), jq
#
# Usage:
#   ./azure/setup.sh
#   SUBSCRIPTION_ID=<sub> STORAGE_ACCOUNT=mydriftsa ./azure/setup.sh
#   GH_ORG=acme-corp APPLY_GH_SECRETS=true ./azure/setup.sh   # also set org secrets
#
# Optional environment variables:
#   LOCATION, RESOURCE_GROUP, CONTAINER_NAME, APP_NAME, RETENTION_DAYS,
#   STORAGE_SKU, SUBJECT_FORMAT (auto|mutable|immutable), REPOS_CONFIG, GH_ORG
# =============================================================================
set -euo pipefail

LOCATION="${LOCATION:-uksouth}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-tf-drift-detection}"
CONTAINER_NAME="${CONTAINER_NAME:-drift-reports}"
APP_NAME="${APP_NAME:-gh-tf-drift-detection}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"
STORAGE_SKU="${STORAGE_SKU:-Standard_LRS}"
SUBJECT_FORMAT="${SUBJECT_FORMAT:-auto}"
GH_ORG="${GH_ORG:-}"
APPLY_GH_SECRETS="${APPLY_GH_SECRETS:-false}"
REPOS_CONFIG="${REPOS_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/repos.json}"

step() { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }

for binary in az gh jq; do
  command -v "$binary" >/dev/null 2>&1 || { echo "error: '$binary' is required" >&2; exit 1; }
done

az account show >/dev/null 2>&1 || { echo "error: not logged in - run 'az login' first" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated - run 'gh auth login'" >&2; exit 1; }
[ -f "$REPOS_CONFIG" ] || { echo "error: repos.json not found at $REPOS_CONFIG" >&2; exit 1; }
case "$SUBJECT_FORMAT" in auto|mutable|immutable) ;; *) echo "error: SUBJECT_FORMAT must be auto, mutable or immutable" >&2; exit 1 ;; esac

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
az account set --subscription "$SUBSCRIPTION_ID"

# Globally unique, stable (re-runs reuse the same account): derive a suffix from
# the subscription + app name instead of using randomness.
if [ -z "${STORAGE_ACCOUNT:-}" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "${SUBSCRIPTION_ID}${APP_NAME}" | sha256sum | cut -c1-10)
  else
    digest=$(printf '%s' "${SUBSCRIPTION_ID}${APP_NAME}" | shasum -a 256 | cut -c1-10)
  fi
  STORAGE_ACCOUNT="tfdriftrpt${digest}"
fi
STORAGE_ACCOUNT=$(printf '%s' "$STORAGE_ACCOUNT" | tr '[:upper:]' '[:lower:]')

# -----------------------------------------------------------------------------
# 1. Resource group
# -----------------------------------------------------------------------------
step "Resource group: $RESOURCE_GROUP ($LOCATION)"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
info "ready"

# -----------------------------------------------------------------------------
# 2. Storage account
#    - allow-blob-public-access false : reports are never anonymously readable
#    - allow-shared-key-access false  : forces Entra (--auth-mode login) auth
# -----------------------------------------------------------------------------
step "Storage account: $STORAGE_ACCOUNT"
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$STORAGE_SKU" \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --output none
info "ready"

STORAGE_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

# The data plane needs an Entra role even for the operator creating the
# container, because shared key access is disabled.
CURRENT_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [ -n "$CURRENT_OBJECT_ID" ]; then
  az role assignment create \
    --assignee-object-id "$CURRENT_OBJECT_ID" \
    --assignee-principal-type User \
    --role "Storage Blob Data Owner" \
    --scope "$STORAGE_ID" \
    --output none 2>/dev/null || true
  info "ensured operator has Storage Blob Data Owner (container creation needs it)"
fi

# -----------------------------------------------------------------------------
# 3. Blob versioning + retention lifecycle (drift reports expire automatically)
# -----------------------------------------------------------------------------
step "Blob service properties + lifecycle policy (${RETENTION_DAYS}d retention)"
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-versioning true \
  --output none

cat > "$WORK_DIR/lifecycle.json" <<JSON
{
  "rules": [
    {
      "enabled": true,
      "name": "expire-drift-reports",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["${CONTAINER_NAME}/"]
        },
        "actions": {
          "baseBlob": {
            "delete": { "daysAfterModificationGreaterThan": ${RETENTION_DAYS} }
          }
        }
      }
    }
  ]
}
JSON

az storage account management-policy create \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --policy @"$WORK_DIR/lifecycle.json" \
  --output none
info "ready"

# -----------------------------------------------------------------------------
# 4. Container
# -----------------------------------------------------------------------------
step "Blob container: $CONTAINER_NAME"
if ! az storage container create \
  --account-name "$STORAGE_ACCOUNT" \
  --name "$CONTAINER_NAME" \
  --auth-mode login \
  --public-access off \
  --output none 2>"$WORK_DIR/container.err"; then
  cat "$WORK_DIR/container.err" >&2
  echo "error: could not create the container. RBAC propagation can take a few" >&2
  echo "       minutes after the role assignment above - re-run this script." >&2
  exit 1
fi
info "ready (private)"

CONTAINER_SCOPE="${STORAGE_ID}/blobServices/default/containers/${CONTAINER_NAME}"

# -----------------------------------------------------------------------------
# 5. Entra app registration + service principal
# -----------------------------------------------------------------------------
step "Entra app registration: $APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  info "created app $APP_ID"
else
  info "reusing app $APP_ID"
fi

APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [ -z "$SP_OBJECT_ID" ]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  info "created service principal"
else
  info "service principal already exists"
fi

# -----------------------------------------------------------------------------
# 6. One federated credential per target repository
#
# The OIDC `sub` claim identifies the CALLER repository, so with a shared
# reusable workflow each target repo still needs its own credential.
#
# Repositories created after 2026-07-15 default to GitHub's immutable subject
# format, which embeds numeric owner/repository IDs. SUBJECT_FORMAT=auto detects
# this from the repository's creation date.
# -----------------------------------------------------------------------------
step "Federated credentials (subject format: $SUBJECT_FORMAT)"

mapfile -t repo_entries < <(jq -r '
  .repositories[]
  | select(.enabled != false)
  | select((.repo // "") != "")
  | [(.repo), (.default_branch // "main")]
  | @tsv
' "$REPOS_CONFIG")

if [ "${#repo_entries[@]}" -eq 0 ]; then
  echo "  warning: repos.json has no enabled repositories - no credentials created" >&2
fi

for entry in "${repo_entries[@]}"; do
  IFS=$'\t' read -r repo branch <<< "$entry"

  if ! repo_meta=$(gh api "repos/$repo" 2>/dev/null); then
    echo "  error: cannot read '$repo' with gh - skipping" >&2
    continue
  fi

  repo_id=$(jq -r '.id' <<< "$repo_meta")
  owner_login=$(jq -r '.owner.login' <<< "$repo_meta")
  owner_id=$(jq -r '.owner.id' <<< "$repo_meta")
  created_at=$(jq -r '.created_at' <<< "$repo_meta")
  repo_name=${repo#*/}

  format="$SUBJECT_FORMAT"
  if [ "$format" = "auto" ]; then
    # ISO-8601 strings compare lexicographically.
    if [[ "${created_at:0:10}" > "2026-07-15" || "${created_at:0:10}" == "2026-07-15" ]]; then
      format="immutable"
    else
      format="mutable"
    fi
  fi

  case "$format" in
    immutable) subject="repo:${owner_login}@${owner_id}/${repo_name}@${repo_id}:ref:refs/heads/${branch}" ;;
    mutable)   subject="repo:${repo}:ref:refs/heads/${branch}" ;;
  esac

  cred_name=$(printf 'gh-%s-%s' "$repo" "$branch" | sed -e 's|[^A-Za-z0-9_-]|-|g' | cut -c1-115)

  jq -n \
    --arg name "$cred_name" \
    --arg subject "$subject" \
    --arg description "GitHub Actions OIDC for ${repo} on ${branch}" \
    '{
       name: $name,
       issuer: "token.actions.githubusercontent.com",
       subject: $subject,
       description: $description,
       audiences: ["api://AzureADTokenExchange"]
     }' > "$WORK_DIR/credential.json"

  if az ad app federated-credential show \
      --id "$APP_OBJECT_ID" \
      --federated-credential-id "$cred_name" >/dev/null 2>&1; then
    az ad app federated-credential update \
      --id "$APP_OBJECT_ID" \
      --federated-credential-id "$cred_name" \
      --parameters @"$WORK_DIR/credential.json" >/dev/null
    info "updated  $cred_name"
  else
    az ad app federated-credential create \
      --id "$APP_OBJECT_ID" \
      --parameters @"$WORK_DIR/credential.json" >/dev/null
    info "created  $cred_name"
  fi
  info "         subject: $subject"
done

# -----------------------------------------------------------------------------
# 7. RBAC - container scope only (least privilege)
# -----------------------------------------------------------------------------
step "Role assignment: Storage Blob Data Contributor (container scope)"
if az role assignment list \
    --assignee "$SP_OBJECT_ID" \
    --scope "$CONTAINER_SCOPE" \
    --query '[0].id' -o tsv 2>/dev/null | grep -q .; then
  info "already assigned"
else
  az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" \
    --scope "$CONTAINER_SCOPE" \
    --output none
  info "assigned (allow a few minutes for propagation)"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
TENANT_ID=$(az account show --query tenantId -o tsv)

cat <<EOF

=============================================================================
Phase 1 Azure resources are ready.
=============================================================================

Add these as ORG-LEVEL GitHub Actions secrets
(Organization Settings > Secrets and variables > Actions), so every target
repository inherits them through 'secrets: inherit':

  AZURE_CLIENT_ID         ${APP_ID}
  AZURE_TENANT_ID         ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID   ${SUBSCRIPTION_ID}
  AZURE_STORAGE_ACCOUNT   ${STORAGE_ACCOUNT}

Reference values:
  Blob container          ${CONTAINER_NAME}
  Container scope         ${CONTAINER_SCOPE}
  Report retention        ${RETENTION_DAYS} days
  Federated credential    one per repo/branch in repos.json

Verify the trust configuration with:
  az ad app federated-credential list --id ${APP_OBJECT_ID} -o table

Phase 2 (Event Grid -> AI analysis -> Teams) will subscribe to this container.
EOF

if [ -n "$GH_ORG" ] && [ "$APPLY_GH_SECRETS" = "true" ]; then
  step "Setting org-level secrets on $GH_ORG"
  gh secret set AZURE_CLIENT_ID --org "$GH_ORG" --body "$APP_ID"
  gh secret set AZURE_TENANT_ID --org "$GH_ORG" --body "$TENANT_ID"
  gh secret set AZURE_SUBSCRIPTION_ID --org "$GH_ORG" --body "$SUBSCRIPTION_ID"
  gh secret set AZURE_STORAGE_ACCOUNT --org "$GH_ORG" --body "$STORAGE_ACCOUNT"
  info "done"
elif [ -n "$GH_ORG" ]; then
  cat <<EOF

To set them now, re-run with APPLY_GH_SECRETS=true, or run manually:

  gh secret set AZURE_CLIENT_ID --org ${GH_ORG} --body "${APP_ID}"
  gh secret set AZURE_TENANT_ID --org ${GH_ORG} --body "${TENANT_ID}"
  gh secret set AZURE_SUBSCRIPTION_ID --org ${GH_ORG} --body "${SUBSCRIPTION_ID}"
  gh secret set AZURE_STORAGE_ACCOUNT --org ${GH_ORG} --body "${STORAGE_ACCOUNT}"
EOF
fi
