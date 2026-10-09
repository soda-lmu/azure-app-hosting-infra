#!/usr/bin/env bash
# Usage: add-app-db.sh <database> <identity-name> <identity-principal-id>
# Creates database <database> on the shared server and gives the managed identity
# <identity-name> (object/principal id <identity-principal-id>) a login role with full
# rights in it, and no access to other apps' databases. Idempotent.
# Runs as an Entra admin: you must be a member of PG_ENTRA_ADMIN_GROUP and logged in (az login).
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source .env; set +a

DB=${1:?database name}; ROLE=${2:?managed identity name}; OID=${3:?managed identity principal id}
[[ $DB =~ ^[a-z][a-z0-9_]*$ ]] || { echo "database name must match ^[a-z][a-z0-9_]*$" >&2; exit 1; }
ADMIN_GROUP=${PG_ENTRA_ADMIN_GROUP:-pg-shared-admins}

# Entra access token as the password; group members log in with the group's name.
TOKEN=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)

docker run --rm -i -e PGPASSWORD="$TOKEN" postgres:18-alpine \
  psql "host=$PG_SERVER.postgres.database.azure.com port=5432 dbname=postgres user=$ADMIN_GROUP sslmode=require" \
  -v ON_ERROR_STOP=1 -v db="$DB" -v role="$ROLE" -v oid="$OID" <<'SQL'
-- Login role bound to the identity's object id (not its display name).
SELECT format('SELECT * FROM pgaadauth_create_principal_with_oid(%L, %L, %L, false, false)',
              :'role', :'oid', 'service')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
-- The admin group owns the database; the app gets full rights inside it. This avoids
-- ownership transfer, which would need the admin to be a member of the app's role.
SELECT format('CREATE DATABASE %I', :'db')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT ALL ON DATABASE :"db" TO :"role";
\connect :db
GRANT ALL ON SCHEMA public TO :"role";
SQL

echo "Database '$DB' ready for managed identity '$ROLE'"
