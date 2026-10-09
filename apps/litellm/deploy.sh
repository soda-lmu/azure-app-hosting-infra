#!/usr/bin/env bash
# Admin deploy of LiteLLM. Safe to re-run.
#  1. setup.bicep -> LITELLM_SECRETS_RG: managed identity, Key Vault, CI identity (admin-only)
#  2. secrets from .env -> Key Vault, if set there and changed
#  3. the identity's database on the shared server (add-app-db.sh)
#  4. main.bicep -> LITELLM_RG: Container Apps environment + app (the part CI will deploy)
# Requires shared/postgres/deploy.sh to have run once, and you in the PG admin group.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
set -a; source "$ROOT/.env"; set +a
SECRETS_RG=${LITELLM_SECRETS_RG:-rg-soda-litellm-secrets-prod}
MI_NAME=${LITELLM_IDENTITY:-id-litellm}

az group create -n "$SECRETS_RG" -l "$LOCATION" -o none
az group create -n "$LITELLM_RG" -l "$LOCATION" -o none

ME=$(az ad signed-in-user show --query id -o tsv)
SETUP=$(az deployment group create -g "$SECRETS_RG" -n litellm-setup -f setup.bicep \
  -p identityName="$MI_NAME" adminPrincipalId="$ME" githubRepo="${GITHUB_REPO:-}" appResourceGroup="$LITELLM_RG" \
  --query "[properties.outputs.identityPrincipalId.value, properties.outputs.keyVaultName.value, properties.outputs.ciClientId.value]" -o tsv)
read -r MI_PRINCIPAL_ID KEYVAULT CI_CLIENT_ID <<< "$(echo $SETUP)"

# Writes a secret if its value is set in .env and differs from Key Vault. Retries while the
# role assignment from setup.bicep is still propagating (can take a few minutes).
put_secret() {
  local name=$1 value=$2 current=
  [[ -n $value ]] || return 0
  for _ in $(seq 30); do
    if current=$(az keyvault secret show --vault-name "$KEYVAULT" -n "$name" --query value -o tsv 2>&1); then break; fi
    if [[ $current == *SecretNotFound* ]]; then current=; break; fi
    sleep 10
  done
  [[ $current == "$value" ]] && return 0
  az keyvault secret set --vault-name "$KEYVAULT" -n "$name" --file <(printf %s "$value") -o none
  echo "Key Vault: updated $name"
}
put_secret litellm-master-key "${LITELLM_MASTER_KEY:-}"
put_secret azure-api-key "${AZURE_API_KEY:-}"

"$ROOT/shared/postgres/add-app-db.sh" litellm "$MI_NAME" "$MI_PRINCIPAL_ID" >/dev/null

# Recorded on the app, so CI can roll back to it. "-dirty": deployed with uncommitted changes.
DEPLOYED_COMMIT=$(git rev-parse HEAD)$([[ -z $(git status --porcelain -- .) ]] || echo -dirty)
export DEPLOYED_COMMIT
URL=$(az deployment group create -g "$LITELLM_RG" -n litellm -p main.bicepparam \
  --query properties.outputs.url.value -o tsv)
echo "Deployed: $URL  (check: curl $URL/health/readiness)"

if [[ -n ${CI_CLIENT_ID:-} ]]; then
  cat <<EOF

GitHub: Settings -> Environments -> litellm-production -> Environment variables (none of these are secrets):
  AZURE_CLIENT_ID=$CI_CLIENT_ID
  AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
  AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  LITELLM_RG=$LITELLM_RG
  LITELLM_SECRETS_RG=$SECRETS_RG
  PG_SERVER=$PG_SERVER
  AZURE_API_BASE=$AZURE_API_BASE
EOF
fi
