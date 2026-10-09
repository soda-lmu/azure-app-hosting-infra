#!/usr/bin/env bash
# Creates the shared PostgreSQL Flexible Server in its own resource group.
# Apps never use the admin login; each gets its own database and role via add-app-db.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source .env; set +a

az provider register -n Microsoft.DBforPostgreSQL --wait

az group create -n "$SHARED_RG" -l "$LOCATION" -o none

# --public-access 0.0.0.0 allows all Azure services, not just ours. Fine for a test;
# for production use VNet integration / private access instead.
az postgres flexible-server create -g "$SHARED_RG" -n "$PG_SERVER" -l "$LOCATION" \
  --tier Burstable --sku-name "$PG_SKU" --storage-size 32 --version 16 \
  --admin-user "$PG_ADMIN_USER" --admin-password "$PG_ADMIN_PASSWORD" \
  --public-access 0.0.0.0 --yes -o none

# Allow this machine, so add-app-db.sh can run SQL as admin.
MY_IP=$(curl -s https://api.ipify.org)
az postgres flexible-server firewall-rule create -g "$SHARED_RG" -n "$PG_SERVER" \
  --rule-name admin-client --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" -o none

echo "Server ready: $PG_SERVER.postgres.database.azure.com"
