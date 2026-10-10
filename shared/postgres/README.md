# Shared PostgreSQL

PostgreSQL 18 Flexible Server shared by several apps, in its own resource group
(`SHARED_RG`, e.g. `rg-admin-appmanagement-shared-database-prod`). Each app gets its own
database and logs in with a managed identity. Defined in `main.bicep`.

| File | Purpose |
|---|---|
| `main.bicep` | Server, Entra admin group, firewall rules, backups |
| `main.bicepparam` | Parameters, read from the repo's `.env` |
| `deploy.sh` | Creates or updates the server. Safe to re-run |
| `add-app-db.sh` | Creates an app's database and the login role for its managed identity |

## Prerequisites
- `az` CLI with Bicep (`az bicep install`), logged in (`az login`); Docker (used to run `psql`).
- You're a member of the Entra group `PG_ENTRA_ADMIN_GROUP` (default `pg-shared-admins`).
  `deploy.sh` prints how to create it if it doesn't exist. After joining, `az login` again.
- `.env` in the repo root (see `.env.example`): `SHARED_RG`, `LOCATION`, `PG_INSTANCE_NAME` (globally
  unique), `PG_HOST` (derived from it), `PG_SKU`, `PG_ENTRA_ADMIN_GROUP`, `PG_ADMIN_USER`, `PG_ADMIN_PASSWORD`
  (`openssl rand -hex 24`), `PG_BACKUP_RETENTION_DAYS`.

## Deploy
```bash
shared/postgres/deploy.sh
```
Looks up the admin group and your public IP, then deploys `main.bicep`. Also the way to roll out
later changes. Preview first with `az deployment group what-if` and the same arguments.

## Logins
- **Apps:** managed identities (Microsoft Entra). No passwords.
- **Admins:** either as a member of the Entra admin group (user = the group's name, password =
  an Entra token), or as the password admin `PG_ADMIN_USER`, for tools without Entra login.
  Keep that password long and random: with "allow all Azure services", anyone in Azure can try it.

Connect at `PG_HOST` (`<PG_INSTANCE_NAME>.postgres.database.azure.com`), port 5432, with
**`sslmode=verify-full`**: it checks the server's certificate and host name, so a token or password can't be handed to an
impostor (`require` only encrypts). Azure's root CAs (DigiCert Global Root G2, Microsoft RSA Root
CA 2017) are in standard CA bundles; with psql use `sslrootcert=system`. Trust only these roots,
never intermediate or server certificates (Microsoft rotates those unannounced). Entra token:
```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
```
Valid about an hour, only checked when connecting. DBeaver's built-in Entra login needs a paid
edition; in DBeaver Community, paste the token as the password or use the password admin.

## Add an app
```bash
shared/postgres/add-app-db.sh <database> <identity-name> <identity-principal-id>
```
Creates the database, and a login role bound to the managed identity's object id with full rights
in that database only. Other apps' roles can't connect to it. The admin group owns the database.
Safe to re-run. Apps' own deploy scripts call it (e.g. `apps/litellm/deploy.sh`).

## Network
- Firewall: all Azure services (so Container Apps can connect), plus the IP that last ran
  `deploy.sh`. If your IP changed, re-run it.
- Going private later: add a private endpoint, VNet-integrate the apps' Container Apps
  environments, then remove the "allow Azure services" rule. The server stays; Container Apps
  environments have to be recreated inside the VNet.

## Operations
- Backups: automatic, point-in-time restore within `PG_BACKUP_RETENTION_DAYS` (7–35), stored
  zone-redundant in the region. **Geo-redundant** as well: also copied to the paired region, so
  after a regional outage the server can be restored there (to the last copied backup, up to an
  hour behind; no point-in-time choice). Only settable at server creation. Germany North, the
  pair of Germany West Central, is an access-restricted region; check with Azure support whether
  a geo-restore there needs prior approval. Cost: backup storage beyond the disk size (32 GB) is
  billed, and geo-redundancy counts backups twice, so for small databases usually nothing.
- Don't stop the server to save money: other apps depend on it (LiteLLM can't enforce budgets
  without it), and Azure restarts a stopped server after 7 days anyway.
- CI: `.github/workflows/shared-postgres-ci.yml` (job `postgres-bicep`) checks the Bicep on every
  PR. Deploying the server stays manual, by admins.
