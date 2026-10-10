# LiteLLM

LiteLLM proxy with budget-limited virtual keys in front of Azure OpenAI, on Azure Container Apps.
Its data lives in its own database on the [shared PostgreSQL server](../../shared/postgres/README.md).

| Resource group | Contents | Defined in |
|---|---|---|
| `LITELLM_SECRETS_RG` (default `rg-soda-litellm-secrets-prod`), **admin-only** | `id-litellm` (managed identity LiteLLM runs as: DB login, Key Vault), `kv-litellm-…` (Key Vault: master key, salt key, Azure OpenAI key), `id-github-deploy-litellm` (CI identity) | `setup.bicep` |
| `LITELLM_RG` (e.g. `rg-soda-litellm-prod`) | `cae-litellm` (Container Apps environment + `log-litellm` workspace), `litellm` (the proxy, 1 replica) | `main.bicep` |

Whoever can manage the identity or the vault can read the secrets, hence the separate admin-only
group. `LITELLM_RG` holds only what routine deployments change and contains no secret values:
the app references them in Key Vault.

| File | Purpose |
|---|---|
| `config.yaml` | LiteLLM config: models, endpoints, prices. No secrets |
| `setup.bicep`, `ci-access.bicep`, `names.bicep` | Admin part: identities, Key Vault, permissions |
| `main.bicep`, `main.bicepparam` | Routine part: environment and app |
| `deploy.sh` | Admin deploy of everything. Safe to re-run |
| `docker-compose.yml` | Local test with the same image and config |

## Prerequisites
- The shared PostgreSQL server is deployed, and you're in its Entra admin group
  (see [its README](../../shared/postgres/README.md)).
- `az` CLI with Bicep, logged in; Docker.
- `.env` in the repo root (see `.env.example`): `LITELLM_RG`, `LITELLM_SECRETS_RG`, `LITELLM_ENV`,
  `LITELLM_APP`, `LITELLM_IDENTITY`, `GITHUB_REPO` (for CI, optional), `AZURE_API_BASE`, and the
  secrets `LITELLM_MASTER_KEY` (`sk-$(openssl rand -hex 24)`), `LITELLM_SALT_KEY`
  (`openssl rand -hex 32`) and `AZURE_API_KEY`.

## Deploy
1. Edit `config.yaml`: one entry per Azure OpenAI deployment, with an explicit price if the model
   is newer than the pinned LiteLLM.
2. Run:
   ```bash
   apps/litellm/deploy.sh
   ```
   It deploys `setup.bicep`, writes the secrets from `.env` to Key Vault if they're set and
   changed (the salt key only once, see below), creates the `litellm` database (`add-app-db.sh`, which Bicep can't do), then deploys
   `main.bicep`. After the first run the secrets can be removed from `.env`.

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
and key from `.env`. Locally Postgres uses a password, since managed identities only exist in Azure.

## Updates and CI/CD
1. LiteLLM is pinned in `main.bicep`. Renovate proposes a new version only once it's 18 days old,
   in one PR with `docker-compose.yml`.
2. **CI** (`.github/workflows/litellm-ci.yml`, jobs `litellm-bicep` and `litellm-health-check`)
   builds the Bicep and starts that image with our `config.yaml` against a local Postgres.
   No Azure access, no secrets.
3. If CI passes, Renovate merges the PR automatically.
4. **Deploy** (`.github/workflows/litellm-deploy.yml`) runs on main when `apps/litellm/` changes:
   logs in to Azure via OIDC as `id-github-deploy-litellm`, deploys `main.bicep`, waits for the
   *new* revision to be ready and `/health/readiness` to report the database connected.
5. If that fails, it redeploys the commit that was running before (recorded as tag `commit` on the
   Container App) and opens an issue assigned to `NOTIFY_USER` (default: repo owner), so you get
   an email. main still contains the failed change: revert or fix it.

What `id-github-deploy-litellm` may do: Contributor on `LITELLM_RG`, attach `id-litellm` to the app.
Nothing on the Key Vault, and it can't add logins to `id-litellm`. Whoever can deploy the app can
deploy code that runs as `id-litellm`; that's why only main deploys, and only you and Renovate can
merge into main (see [repository rules](../../README.md#repository-rules)).

### One-time GitHub setup for LiteLLM
1. `GITHUB_REPO=owner/name` in `.env`, then run `deploy.sh`. It creates `id-github-deploy-litellm`
   and prints the variables for step 2.
2. Settings → Environments → **New environment `litellm-production`** (the name must match):
   - Deployment branches and tags: **Selected branches → `main`**. No required reviewers.
   - Environment variables: the values `deploy.sh` printed. Optionally `NOTIFY_USER` (needed if
     the repo belongs to an organization).

## Notes
- At most one replica: budget/rate-limit state is cached per instance. Scaling out needs Redis.
- Scales to zero when idle (by default after about 5 minutes without requests): no compute cost
  then, but the first request afterwards waits for the container and LiteLLM to start.
- Costs come from LiteLLM's price table, not Azure billing. Override per model in `config.yaml`
  if your pricing differs.
- Spend logs (one row per request, ~6 KB) are deleted after 90 days
  (`general_settings.maximum_spend_logs_retention_period` in `config.yaml`). Budgets and the daily
  usage summaries are kept; only per-request detail older than that is gone.
