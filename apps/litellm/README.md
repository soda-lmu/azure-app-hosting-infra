# LiteLLM

LiteLLM proxy with budget-limited virtual keys in front of Azure AI models, on Azure Container Apps.
Its data lives in its own database on the [shared PostgreSQL server](../../shared/postgres/README.md).

| Resource group | Contents | Defined in |
|---|---|---|
| `rg-litellm-secrets-prod`, **admin-only** | `id-litellm-prod` (identity LiteLLM runs as), `kv-litellm-…` (Key Vault: master key, salt key), `id-litellm-github-deploy-prod` (identity GitHub Actions deploys with) | `setup.bicep` |
| `rg-litellm-prod` | `cae-litellm-prod` (Container Apps environment) + `log-litellm-prod` (its log workspace), `ca-litellm-prod` (the proxy, 1 replica) | `main.bicep` |

All names are defined once in [`names.bicep`](names.bicep) (in git, not secret). The Bicep files
import them, `deploy.sh` and the GitHub workflow read them from the compiled file; to use other
names, change that file.
`deploy.sh` shows the resource groups and asks you to confirm them before it deploys.

Whoever can manage the identity or the vault can read the secrets, hence the separate admin-only
group. `rg-litellm-prod` holds only what routine deployments change and contains no secret values:
the app references them in Key Vault.

| File | Purpose |
|---|---|
| `config.yaml` | LiteLLM config: models, endpoints, prices. No secrets |
| `names.bicep` | All resource names |
| `setup.bicep`, `github-access.bicep`, `ai-access.bicep` | Admin part: identities, Key Vault, permissions |
| `main.bicep`, `main.bicepparam` | Routine part: environment and app |
| `deploy.sh` | Admin deploy of everything. Safe to re-run |
| `docker-compose.yml` | Local test with the same image and config |

## Identities
Who can access what. No identity holds an Azure AI key or a database password: Azure apps log in
with Entra tokens.

| Identity | Used by | Can access | Can't |
|---|---|---|---|
| `id-litellm-prod` (`appIdentity` in `setup.bicep`) | the LiteLLM container | **Key Vault:** read secrets (Key Vault Secrets User). **Azure AI resource:** call models (Cognitive Services OpenAI User, `ai-access.bicep`). **Postgres:** all rights in its own `litellm_db` database (`add-app-db.sh`) | read Azure AI keys, change Azure resources, see other apps' databases |
| `id-litellm-github-deploy-prod` (`githubIdentity`) | GitHub Actions, only from environment `litellm-production` (main branch) | **`rg-litellm-prod`:** Contributor (`github-access.bicep`). **`id-litellm-prod`:** attach it to the app (Managed Identity Operator) | Key Vault, the secrets resource group, adding logins to `id-litellm-prod`, Postgres, the Azure AI resource |
| You (admin, signed in to `az`) | `deploy.sh` | **Key Vault:** write secrets (Key Vault Secrets Officer). Everything else through your subscription role (Owner): needed to assign the roles above | |

- **Indirect access through deployments.** `id-litellm-github-deploy-prod` can't read
  secrets itself, but it can deploy code that runs as `id-litellm-prod` and so reads them.
  That's why only main deploys, and only you and Renovate can merge into main (see
  [repository rules](../../README.md#repository-rules)).
- **Adding a role:** in `setup.bicep` (or the matching module for another resource group), then
  run `deploy.sh`. Removing a role from the template doesn't remove it in Azure: delete it with
  `az role assignment delete`.

## Prerequisites
- The shared PostgreSQL server is deployed, and you're in its Entra admin group
  (see [its README](../../shared/postgres/README.md)).
- `az` CLI with Bicep, logged in; Docker; `jq`.
- `.env` in the repo root (see `.env.example`): `GITHUB_REPO` (for CI, optional), `PG_HOST`,
  `AZURE_API_BASE`, and the secrets `LITELLM_MASTER_KEY` (`sk-$(openssl rand -hex 24)`) and `LITELLM_SALT_KEY`
  (`openssl rand -hex 32`). `AZURE_API_KEY` only for the local test: Azure uses `id-litellm-prod`.

## Deploy
1. Edit `config.yaml`: one entry per Azure OpenAI deployment, with an explicit price if the model
   is newer than the pinned LiteLLM.
2. Run:
   ```bash
   apps/litellm/deploy.sh
   ```
   It deploys `setup.bicep`, writes the secrets from `.env` to Key Vault if they're set and
   changed (the salt key only once, see below), creates the `litellm_db` database (`add-app-db.sh`, which Bicep
   can't do), then deploys `main.bicep`. After the first run the secrets can be removed from `.env`.

- A new revision rolls out whenever `config.yaml` changes.
- To change a key: put the new value in `.env` and re-run `deploy.sh`, or
  `az keyvault secret set --vault-name <kv> -n litellm-master-key --value …`. The app picks up the
  new version within 30 minutes and restarts by itself; for immediately,
  `az containerapp revision restart`.
- **Never change the salt key** (`litellm-salt-key`). LiteLLM encrypts credentials it stores in its
  database with it (e.g. models or provider keys added in the admin UI); a new salt key makes them
  unreadable. `deploy.sh` therefore only writes it if it's missing, and stops if `.env` has a
  different value. Keep a copy somewhere safe: losing it has the same effect. Because of the
  separate salt key, the master key can be rotated freely.

## Use
```bash
curl https://<fqdn>/health/readiness
curl -X POST https://<fqdn>/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["gpt-6-luna"],"max_budget":50,"budget_duration":"30d"}'
```

## Local test
```bash
cd apps/litellm && docker compose --env-file ../../.env up -d
```
Same image and config on `localhost:4000` (master key `sk-local-test`), using the Azure endpoint
and `AZURE_API_KEY` from `.env`. Managed identities only exist in Azure, so locally LiteLLM uses the
API key for models and a password for Postgres. If `AZURE_API_KEY` is set, it always takes
precedence over the identity, also in Azure: don't add it to the Container App.

## Updates and CI/CD
1. LiteLLM is pinned in `main.bicep`. Renovate proposes a new version only once it's 18 days old,
   in one PR with `docker-compose.yml`.
2. **CI** (`.github/workflows/litellm-ci.yml`, jobs `litellm-bicep` and `litellm-health-check`)
   builds the Bicep and starts that image with our `config.yaml` against a local Postgres.
   No Azure access, no secrets.
3. If CI passes, Renovate merges the PR automatically.
4. **Deploy** (`.github/workflows/litellm-deploy.yml`) runs on main when `apps/litellm/` changes:
   logs in to Azure via OIDC as `id-litellm-github-deploy-prod`, deploys `main.bicep`, waits for the
   *new* revision to be ready and `/health/readiness` to report the database connected.
5. If that fails, it redeploys the commit that was running before (recorded as tag `commit` on the
   Container App) and opens an issue assigned to `NOTIFY_USER` (default: repo owner), so you get
   an email. main still contains the failed change: revert or fix it.

What `id-litellm-github-deploy-prod` may do: see [Identities](#identities).

### One-time GitHub setup for LiteLLM
1. `GITHUB_REPO=owner/name` in `.env`, then run `deploy.sh`. It creates
   `id-litellm-github-deploy-prod` and prints the values for step 2. Put `LITELLM_GITHUB_DEPLOY_CLIENT_ID` into `.env` as well.
2. Settings → Environments → **New environment `litellm-production`** (the name must match):
   - Deployment branches and tags: **Selected branches → `main`**. No required reviewers.
   - **Environment secrets:** `LITELLM_GITHUB_DEPLOY_CLIENT_ID`, `AZURE_TENANT_ID`,
     `AZURE_SUBSCRIPTION_ID`, `PG_HOST`, `AZURE_API_BASE`, as printed. They grant no access by
     themselves (logging in also needs the environment's OIDC token), but as secrets they're
     masked in the logs.
   - **Environment variables:** none needed (resource names come from `names.bicep`). Optionally
     `NOTIFY_USER` (needed if the repo belongs to an organization).

The environment secrets are copies of the values in `.env` (see the block marked there) and must
be kept in sync by hand: if they differ, the next GitHub deploy reverts what `deploy.sh` set.
`deploy.sh` marks every value that differs from `.env` in its output.

## Notes
- Cost alerts: monthly Azure budgets of 8 € (`rg-litellm-prod`) and 1 € (`rg-litellm-secrets-prod`,
  the minimum: Azure only accepts whole amounts), in `setup.bicep`. When the actual cost exceeds the
  budget, the Owners get an email ([`shared/budget.bicep`](../../shared/budget.bicep)).
  Budgets only alert, they don't stop anything. Model usage is billed on the Azure AI resource,
  not here: LiteLLM's key budgets limit that.
- At most one replica: budget/rate-limit state is cached per instance. Scaling out needs Redis.
- Scales to zero when idle (by default after about 5 minutes without requests): no compute cost
  then, but the first request afterwards waits for the container and LiteLLM to start.
- Costs come from LiteLLM's price table, not Azure billing. Override per model in `config.yaml`
  if your pricing differs.
- Spend logs (one row per request, ~6 KB) are deleted after 90 days
  (`general_settings.maximum_spend_logs_retention_period` in `config.yaml`). Budgets and the daily
  usage summaries are kept; only per-request detail older than that is gone.
