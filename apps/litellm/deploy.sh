#!/usr/bin/env bash
# Creates the LiteLLM resource group, Container Apps environment and its database
# on the shared server (first run), then deploys app.yaml.
# Requires shared/postgres/create-server.sh to have run once.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
set -a; source "$ROOT/.env"; set +a

az provider register -n Microsoft.App --wait
az provider register -n Microsoft.OperationalInsights --wait

az group create -n "$LITELLM_RG" -l "$LOCATION" -o none
az containerapp env show -n "$LITELLM_ENV" -g "$LITELLM_RG" -o none 2>/dev/null \
  || az containerapp env create -n "$LITELLM_ENV" -g "$LITELLM_RG" -l "$LOCATION" -o none

"$ROOT/shared/postgres/add-app-db.sh" litellm "$LITELLM_DB_PASSWORD" >/dev/null

export ENV_ID=$(az containerapp env show -n "$LITELLM_ENV" -g "$LITELLM_RG" --query id -o tsv)
export DATABASE_URL="postgresql://litellm:$LITELLM_DB_PASSWORD@$PG_SERVER.postgres.database.azure.com:5432/litellm?sslmode=require"

# Render: substitute only our variables (config.yaml may contain other $ text),
# then indent config.yaml into the block scalar.
RENDERED=$(mktemp --suffix=.rendered.yaml)
trap 'rm -f "$RENDERED"' EXIT
envsubst '${LITELLM_APP} ${LOCATION} ${ENV_ID} ${LITELLM_MASTER_KEY} ${DATABASE_URL} ${AZURE_API_KEY} ${AZURE_API_BASE}' < app.yaml \
  | awk 'FNR==NR { cfg = cfg "          " $0 "\n"; next }
         /^ *__LITELLM_CONFIG__$/ { printf "%s", cfg; next } { print }' config.yaml - > "$RENDERED"

if az containerapp show -n "$LITELLM_APP" -g "$LITELLM_RG" -o none 2>/dev/null; then
  az containerapp update -n "$LITELLM_APP" -g "$LITELLM_RG" --yaml "$RENDERED" -o none
  # Secret-only changes (e.g. config.yaml) don't create a new revision; restart to pick them up.
  REV=$(az containerapp show -n "$LITELLM_APP" -g "$LITELLM_RG" --query properties.latestRevisionName -o tsv)
  az containerapp revision restart -n "$LITELLM_APP" -g "$LITELLM_RG" --revision "$REV" -o none
else
  az containerapp create -n "$LITELLM_APP" -g "$LITELLM_RG" --yaml "$RENDERED" -o none
fi

FQDN=$(az containerapp show -n "$LITELLM_APP" -g "$LITELLM_RG" --query properties.configuration.ingress.fqdn -o tsv)
echo "Deployed: https://$FQDN  (check: curl https://$FQDN/health/liveliness)"
