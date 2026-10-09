# LiteLLM on Azure Container Apps

LiteLLM proxy with budget-limited virtual keys in front of Azure OpenAI, backed by a
**shared** PostgreSQL Flexible Server that other apps can use too. Infrastructure is Bicep.

```
rg-admin-appmanagement-shared-database-prod  pg-shared-…   PostgreSQL 18, Entra + password auth, one DB per app    shared/postgres/main.bicep
rg-soda-litellm-secrets-prod                 id-litellm    managed identity LiteLLM runs as (DB login, Key Vault)  apps/litellm/setup.bicep
                                             kv-litellm-…  Key Vault: master key, Azure OpenAI key                 apps/litellm/setup.bicep
rg-soda-litellm-prod                         cae-litellm   Container Apps environment (+ log-litellm workspace)    apps/litellm/main.bicep
                                             litellm       LiteLLM proxy (1 replica)                               apps/litellm/main.bicep
```

`rg-soda-litellm-secrets-prod` is admin-only: whoever can manage the identity or the vault can read the
secrets. `rg-soda-litellm-prod` holds only what routine deployments change, and contains no secret values;
the app references them in Key Vault.

## Prerequisites
`az` CLI with Bicep (`az bicep install`; logged in: `az login`), Docker (used to run `psql`).
You must be a member of the Entra group `PG_ENTRA_ADMIN_GROUP` (default `pg-shared-admins`);
`shared/postgres/deploy.sh` prints how to create it if it doesn't exist.

## Setup
1. `cp .env.example .env` and fill it in. Generate the master key with `sk-$(openssl rand -hex 24)`,
   passwords with `openssl rand -hex 24`.
2. Edit `apps/litellm/config.yaml`: one entry per Azure OpenAI deployment, with an explicit price
   if the model is newer than the pinned LiteLLM.
3. Shared server: `shared/postgres/deploy.sh`
4. LiteLLM: `apps/litellm/deploy.sh`
5. Optional, for automatic updates: see [One-time GitHub setup](#one-time-github-setup).

Both scripts are safe to re-run, and are also how you roll out every later change. The
`.bicepparam` files read their values from `.env`. To preview changes first, run
`az deployment group what-if` with the same arguments the script uses.

`apps/litellm/deploy.sh` deploys identity and Key Vault (`setup.bicep`), writes the two secrets
from `.env` to Key Vault if they're set and changed, creates the identity's `litellm` database
(`add-app-db.sh`, which Bicep can't do), then deploys environment and app (`main.bicep`).
After that the secrets can be removed from `.env`.

- A new revision rolls out whenever `config.yaml` changes.
- To change a key: put the new value in `.env` and re-run `deploy.sh`, or
  `az keyvault secret set --vault-name <kv> -n litellm-master-key --value …`.
  The app picks up the new version within 30 minutes and restarts by itself; for immediately,
  `az containerapp revision restart`.

## Use
```bash
curl https://<fqdn>/health/readiness
curl -X POST https://<fqdn>/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["gpt-6-luna"],"max_budget":50,"budget_duration":"30d"}'
```

## Shared PostgreSQL
- **Logins:** apps use managed identities (Entra). Admins log in either as members of the Entra
  admin group, or with the password admin `PG_ADMIN_USER` for tools without Entra login
  (e.g. DBeaver Community).
- Add another app's database: `shared/postgres/add-app-db.sh <database> <identity-name> <identity-principal-id>`.
  The identity gets a login role with full rights in that database only; other roles can't connect to it.
- Browse it as the password admin, or via Entra: user = the admin group's name, password = an Entra token:
  `export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)`
  (valid ~1 hour, only checked when connecting). Host `<PG_SERVER>.postgres.database.azure.com:5432`,
  `sslmode=require`. DBeaver's built-in Entra login needs a paid edition; in Community, paste the
  token as the password.
- Firewall: all Azure services, plus the IP that last ran `shared/postgres/deploy.sh`. If your IP
  changed, re-run that script.
- Going private later: add a private endpoint and VNet-integrate the Container Apps
  environments, then remove the "allow Azure services" rule. The server stays; the Container
  Apps environment has to be recreated inside the VNet.
- Don't stop the server to save money: other apps depend on it, and LiteLLM can't enforce
  budgets without it.

## Local test
`cd apps/litellm && docker compose --env-file ../../.env up -d` gives the same image and config
on `localhost:4000` (master key `sk-local-test`), using the Azure endpoint and key from `.env`.
Locally Postgres uses a password, since managed identities only exist in Azure.

## Updates and CI/CD
1. LiteLLM is pinned in `apps/litellm/main.bicep`. Renovate proposes a new version only once it's
   18 days old (all updates wait 18 days; GitHub Actions are pinned to commit hashes), in one PR
   with `docker-compose.yml`.
2. **CI** (`.github/workflows/litellm-ci.yml`, jobs `litellm-bicep` and `litellm-health-check`) builds the Bicep and starts
   that image with our `config.yaml` against a local Postgres. No Azure access, no secrets.
   `.github/workflows/shared-postgres-ci.yml` (job `postgres-bicep`) checks the shared server's
   Bicep; deploying that server stays manual.
3. If CI passes, Renovate merges the LiteLLM PR automatically. Other PRs are merged by you.
4. **Deploy** (`.github/workflows/litellm-deploy.yml`) runs on main when `apps/litellm/` changes: logs in to
   Azure via OIDC as `id-github-deploy-litellm`, deploys `main.bicep`, waits for the *new* revision to be
   ready and `/health/readiness` to report the database connected.
5. If that fails, it redeploys the commit that was running before (recorded as tag `commit` on the
   Container App) and opens an issue assigned to `NOTIFY_USER` (default: repo owner), so you get an
   email. main still contains the failed change: revert or fix it.

What `id-github-deploy-litellm` may do: Contributor on `rg-soda-litellm-prod`, attach `id-litellm` to the app.
Nothing on the Key Vault, and it can't add logins to `id-litellm`. Note that whoever can deploy the
app can deploy code that runs as `id-litellm`; that's why only main deploys, and only you and
Renovate can merge into main.

### One-time GitHub setup
1. `GITHUB_REPO=owner/name` in `.env`, then run `apps/litellm/deploy.sh` once. It creates
   `id-github-deploy-litellm` and prints the variables for step 2.
2. Settings → Environments → **New environment `litellm-production`**:
   - Deployment branches and tags: **Selected branches → `main`**. No required reviewers.
   - Environment variables: the values `deploy.sh` printed. Optionally `NOTIFY_USER` (needed if
     the repo belongs to an organization).
3. Install the [Renovate app](https://github.com/apps/renovate) for this repo only.
4. Settings → General → **Allow auto-merge**.
5. Settings → Rules → Rulesets (private repos need GitHub Pro/Team/Enterprise), both targeting
   the default branch:
   - **`main: who can merge`**: rule *Restrict updates*. Bypass list: *Repository admin* and the
     *Renovate* app. Everyone else with write access can open PRs but not merge.
   - **`main: quality`**: *Require a pull request before merging* (0 approvals), *Require status
     checks to pass* (`litellm-bicep`, `litellm-health-check`, `postgres-bicep`), *Block force pushes*,
     *Restrict deletions*.
     Bypass list: empty, so CI is required for you and Renovate too.
6. Keep the admin role to yourself: admins can change these rules.

## Notes
- Exactly one replica: budget/rate-limit state is cached per instance. Scaling out needs Redis.
- Costs come from LiteLLM's price table, not Azure billing. Override per model in `config.yaml`
  if your pricing differs.
