#!/usr/bin/env bash
# Admin deploy of LiteLLM. Safe to re-run.
#  1. setup.bicep -> LITELLM_SECRETS_RG: app identity, Key Vault, GitHub Actions identity (admin-only),
#     plus the app identity's permission to call models on the Azure AI resource
#  2. secrets from .env -> Key Vault, if set there and changed
#  3. the identity's database on the shared server (add-app-db.sh)
#  4. main.bicep -> LITELLM_RG: Container Apps environment + app (the part CI will deploy)
# Requires shared/postgres/deploy.sh to have run once, and you in the PG admin group.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
set -a; source "$ROOT/.env"; set +a
SECRETS_RG=${LITELLM_SECRETS_RG:-rg-soda-litellm-secrets-prod}
APP_IDENTITY=${LITELLM_IDENTITY:-id-litellm}

az group create -n "$SECRETS_RG" -l "$LOCATION" -o none
az group create -n "$LITELLM_RG" -l "$LOCATION" -o none

# The Azure AI resource whose models LiteLLM calls, found by its endpoint's subdomain.
AI_HOST=${AZURE_API_BASE#https://}
read -r AI_ACCOUNT AI_RG <<< "$(az cognitiveservices account list \
  --query "[?properties.customSubDomainName=='${AI_HOST%%.*}'] | [0].join(' ', [name, resourceGroup])" -o tsv)"
[[ -n $AI_ACCOUNT ]] || { echo "No Azure AI resource found for $AZURE_API_BASE" >&2; exit 1; }

ME=$(az ad signed-in-user show --query id -o tsv)
SETUP=$(az deployment group create -g "$SECRETS_RG" -n litellm-setup -f setup.bicep \
  -p appIdentityName="$APP_IDENTITY" adminPrincipalId="$ME" githubRepo="${GITHUB_REPO:-}" appResourceGroup="$LITELLM_RG" \
     aiAccountName="$AI_ACCOUNT" aiResourceGroup="$AI_RG" \
  --query "[properties.outputs.appIdentityPrincipalId.value, properties.outputs.keyVaultName.value, properties.outputs.githubIdentityClientId.value]" -o tsv)
read -r APP_PRINCIPAL_ID KEYVAULT GITHUB_CLIENT_ID <<< "$(echo $SETUP)"

# Writes a secret if its value is set in .env and differs from Key Vault. Retries while the
# role assignment from setup.bicep is still propagating (can take a few minutes).
# Mode "once": only written if missing; a different existing value stops the script.
put_secret() {
  local name=$1 value=$2 mode=${3:-update} current='' state=unreachable
  [[ -n $value ]] || return 0
  for _ in $(seq 30); do
    if current=$(az keyvault secret show --vault-name "$KEYVAULT" -n "$name" --query value -o tsv 2>&1); then state=exists; break; fi
    if [[ $current == *SecretNotFound* ]]; then current=; state=missing; break; fi
    sleep 10
  done
  [[ $state == unreachable ]] && { echo "Key Vault: can't read $name: $current" >&2; exit 1; }
  [[ $current == "$value" ]] && return 0
  if [[ $mode == once && $state == exists ]]; then
    echo "Key Vault: $name is already set and differs from .env. Not changed: changing it makes" >&2
    echo "everything LiteLLM encrypted in its database unreadable. Fix .env or remove the value there." >&2
    exit 1
  fi
  az keyvault secret set --vault-name "$KEYVAULT" -n "$name" --file <(printf %s "$value") -o none
  echo "Key Vault: updated $name"
}
put_secret litellm-master-key "${LITELLM_MASTER_KEY:-}"
put_secret litellm-salt-key "${LITELLM_SALT_KEY:-}" once

"$ROOT/shared/postgres/add-app-db.sh" litellm "$APP_IDENTITY" "$APP_PRINCIPAL_ID" >/dev/null

# Recorded on the app, so CI can roll back to it. "-dirty": deployed with uncommitted changes.
DEPLOYED_COMMIT=$(git rev-parse HEAD)$([[ -z $(git status --porcelain -- .) ]] || echo -dirty)
export DEPLOYED_COMMIT
URL=$(az deployment group create -g "$LITELLM_RG" -n litellm -p main.bicepparam \
  --query properties.outputs.url.value -o tsv)
echo "Deployed: $URL  (check: curl $URL/health/readiness)"

if [[ -n ${GITHUB_CLIENT_ID:-} ]]; then
  # The values GitHub must have. Compared with .env, where the same values are kept in sync by hand.
  github_secret() {
    local note=''
    [[ ${!1:-} == "$2" ]] || note="   <- differs from .env, update it there too"
    echo "  $1=$2$note"
  }
  echo
  echo "GitHub: Settings -> Environments -> litellm-production. Keep in sync with .env."
  echo "Environment secrets:"
  github_secret LITELLM_GITHUB_DEPLOY_CLIENT_ID "$GITHUB_CLIENT_ID"
  github_secret AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"
  github_secret AZURE_SUBSCRIPTION_ID "$(az account show --query id -o tsv)"
  github_secret PG_HOST "$PG_HOST"
  github_secret AZURE_API_BASE "$AZURE_API_BASE"
  echo "Environment variables:"
  echo "  LITELLM_RG=$LITELLM_RG"
  echo "  LITELLM_SECRETS_RG=$SECRETS_RG"
fi
