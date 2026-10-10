#!/usr/bin/env bash
# Creates or updates the shared PostgreSQL server (main.bicep). Safe to re-run; also
# updates the admin firewall rule to the IP you're running from.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ../../.env; set +a

read -rp "The server will be deployed into resource group $SHARED_RG (created if missing). Use this name? [y/N] " answer
[[ $answer == [yY]* ]] || { echo "Not deployed. Change SHARED_RG in .env." >&2; exit 1; }

ADMIN_GROUP=${PG_ENTRA_ADMIN_GROUP:-pg-shared-admins}
ADMIN_GROUP_ID=$(az ad group show -g "$ADMIN_GROUP" --query id -o tsv 2>/dev/null) || {
  cat >&2 <<EOF
Entra group '$ADMIN_GROUP' not found. Create it and add yourself, then re-run:
  az ad group create --display-name $ADMIN_GROUP --mail-nickname $ADMIN_GROUP
  az ad group member add -g $ADMIN_GROUP --member-id \$(az ad signed-in-user show --query id -o tsv)
EOF
  exit 1
}
ADMIN_CLIENT_IP=$(curl -s https://api.ipify.org)
export ADMIN_GROUP_ID ADMIN_CLIENT_IP

az group create -n "$SHARED_RG" -l "$LOCATION" -o none
az deployment group create -g "$SHARED_RG" -n pg-shared -p main.bicepparam -o none

echo "Server ready: $PG_HOST (admin client IP: $ADMIN_CLIENT_IP)"
