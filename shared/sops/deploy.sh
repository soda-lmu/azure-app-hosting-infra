#!/usr/bin/env bash
# Creates or updates the Key Vault to work with SOPS (main.bicep). Safe to re-run.
# Reads SHARED_RG, LOCATION and PG_ENTRA_ADMIN_GROUP from .env or, once that is encrypted,
# from config.sops.env.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f ../../.env ]]; then
  settings=$(< ../../.env)
else
  settings=$(sops decrypt ../../config.sops.env) # assignment, so a failure stops the script
fi
set -a; source /dev/stdin <<< "$settings"; set +a

read -rp "The Key Vault will be deployed into resource group $SHARED_RG (created if missing). Use this name? [y/N] " answer
[[ $answer == [yY]* ]] || { echo "Not deployed. Change SHARED_RG in the settings." >&2; exit 1; }

ADMIN_GROUP=${PG_ENTRA_ADMIN_GROUP:-pg-shared-admins}
ADMIN_GROUP_ID=$(az ad group show -g "$ADMIN_GROUP" --query id -o tsv 2>/dev/null) || {
  echo "Entra group '$ADMIN_GROUP' not found. Create it first (shared/postgres/deploy.sh prints how)." >&2
  exit 1
}
export ADMIN_GROUP_ID

az group create -n "$SHARED_RG" -l "$LOCATION" -o none
KEY_URL=$(az deployment group create -g "$SHARED_RG" -n sops -p main.bicepparam \
  --query properties.outputs.keyUrl.value -o tsv)

echo "SOPS key: $KEY_URL (usable by the members of $ADMIN_GROUP)"
grep -qF "$KEY_URL" ../../.sops.yaml ||
  echo "Set azure_keyvault in .sops.yaml to this URL (and, if config.sops.env exists: sops updatekeys config.sops.env)." >&2
