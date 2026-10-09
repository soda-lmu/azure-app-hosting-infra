#!/usr/bin/env bash
# Usage: add-app-db.sh <app> <password>
# Creates login role <app> and database <app> owned by it, on the shared server.
# Idempotent: re-running resets the role's password.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source .env; set +a

APP=${1:?app name}; APP_PW=${2:?password}
[[ $APP =~ ^[a-z][a-z0-9_]*$ ]] || { echo "app name must match ^[a-z][a-z0-9_]*$" >&2; exit 1; }

psql_admin() {
  docker run --rm -i -e PGPASSWORD="$PG_ADMIN_PASSWORD" postgres:16-alpine \
    psql "host=$PG_SERVER.postgres.database.azure.com port=5432 dbname=postgres user=$PG_ADMIN_USER sslmode=require" \
    -v ON_ERROR_STOP=1 -v app="$APP" -v pw="$APP_PW" "$@"
}

psql_admin <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'app')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app') \gexec
ALTER ROLE :"app" WITH LOGIN PASSWORD :'pw';
-- PG16: the admin needs membership to hand ownership to the role.
GRANT :"app" TO CURRENT_USER;
SELECT format('CREATE DATABASE %I OWNER %I', :'app', :'app')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app') \gexec
-- Keep other apps' roles out of this database.
REVOKE ALL ON DATABASE :"app" FROM PUBLIC;
SQL

echo "postgresql://$APP:<password>@$PG_SERVER.postgres.database.azure.com:5432/$APP?sslmode=require"
