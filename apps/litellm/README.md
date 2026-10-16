# LiteLLM

LiteLLM proxy with budget-limited virtual keys in front of Azure AI models, on Azure Container Apps.
Its data lives in its own database on the [shared PostgreSQL server](../../shared/postgres/README.md).

| Resource group | Contents | Defined in |
|---|---|---|
| `rg-litellm-secrets-prod`, **admin-only** | `id-litellm-prod` (identity LiteLLM runs as), `kv-litellm-…` (Key Vault: master key, salt key), `id-litellm-github-deploy-prod` (identity GitHub Actions deploys with) | `setup.bicep` |
| `rg-litellm-prod` **managed through GitHub** | `cae-litellm-prod` (Container Apps environment, with `cert-litellm-prod`: TLS certificate of the custom domain) + `log-litellm-prod` (its log workspace), `ca-litellm-prod` (the proxy, 1 replica) | `main.bicep` |

An administrator needs to run `deploy.sh` (`mise run deploy:litellm`) a single time. This creates every resource defined in `setup.bicep`, writes the master and salt keys to Key Vault, creates the `litellm_db` database (which Bicep can't do) and also executes `main.bicep`. Routine deployments, orchestrated by GitHub, only run `main.bicep`.

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
| `docker-compose.yml`, `health-check.sh` | Local test with the same image and config (`mise run test:litellm`); CI uses both |

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
  That's why only main deploys, and only people with write access can merge into main (see
  [repository rules](../../README.md#repository-rules)).
- **Adding a role:** in `setup.bicep` (or the matching module for another resource group), then
  run `deploy.sh`. Removing a role from the template doesn't remove it in Azure: delete it with
  `az role assignment delete`.

## Prerequisites
- The shared PostgreSQL server is deployed, and you're in its Entra admin group
  (see [its README](../../shared/postgres/README.md)).
- `az` CLI with Bicep, logged in; `mise` and `sops`; Docker; `jq`; `dig` (Debian/Ubuntu: `dnsutils`).
- Settings in `config.sops.yaml` (see `config.template.yaml`): `GITHUB_REPO` (for CI, optional), `PG_HOST`,
  `AZURE_API_BASE`, and the secrets `LITELLM_MASTER_KEY` (`sk-$(openssl rand -hex 24)`) and `LITELLM_SALT_KEY`
  (`openssl rand -hex 32`).

## Deploy
1. Edit `config.yaml`: one entry per Azure OpenAI deployment, with an explicit price if the model
   is newer than the pinned LiteLLM.
2. Run:
   ```bash
   mise run deploy:litellm
   ```
- On the first run, `deploy.sh` prints two DNS records for the [custom domain](#custom-domain).
  Create them and run it again.
- A new revision rolls out whenever `config.yaml` (or the LiteLLM version in `main.bicep`) changes.
- To change the `LITELLM_MASTER_KEY`: put the new value in `config.sops.yaml` and re-run `mise run deploy:litellm`, or
  `az keyvault secret set --vault-name <kv> -n litellm-master-key --value …`.
- **Never change the salt key** (`litellm-salt-key`). LiteLLM encrypts credentials it stores in its
  database with it (e.g. models or provider keys added in the admin UI); a new salt key makes them
  unreadable. Keep a copy somewhere safe: losing it has the same effect.

## Custom domain
LiteLLM is served at `https://<customDomain>` (`customDomain` in `names.bicep`; empty:
no custom domain). The `*.azurecontainerapps.io` address keeps working too.

The DNS zone containing `<customDomain>` needs two records. `deploy.sh` prints them with the actual values
until they resolve:

| Name | Type | Value |
|---|---|---|
| `<customDomain>` | CNAME | the app's address, `ca-litellm-prod.<hash>.<region>.azurecontainerapps.io` |
| `asuid.<customDomain>` | TXT | the domain verification id (`az containerapp show -n ca-litellm-prod -g rg-litellm-prod --query properties.customDomainVerificationId`) |

Once they resolve, `deploy.sh` deploys `main.bicep` in two stages (`customDomainStage`):
- `hostname` adds the hostname to the app and has Azure issue a free managed certificate
`cert-litellm-prod` (renewed automatically)
- `bound` serves the domain with it.

Routine deploys use stage `bound`. Until the certificate exists, they deploy without the domain
(GitHub logs a warning).

To change the domain: change `customDomain` and give `customDomainCertificate` a new name in
`names.bicep`, run `deploy.sh`, then delete the old certificate
(`az containerapp env certificate delete -g rg-litellm-prod -n cae-litellm-prod -c <old name>`).

## Use

Admin panel: `https://<customDomain>/ui`. Or:

```bash
LITELLM_MASTER_KEY=$(sops decrypt --extract '["LITELLM_MASTER_KEY"]' config.sops.yaml)
curl https://<customDomain>/health/readiness
curl -X POST https://<customDomain>/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["gpt-6-luna"],"max_budget":50,"budget_duration":"30d"}'
```

## Local test
```bash
cp apps/litellm/.env.example apps/litellm/.env   # once; fill in AZURE_API_BASE and AZURE_API_KEY
mise run test:litellm
```
Starts LiteLLM with `docker compose`, runs the same check as CI (`health-check.sh`), then sends one
small request to every model in `config.yaml` (costs a few tokens). It keeps running afterwards;
stop it with `docker compose down` in `apps/litellm`. Same image and config on `localhost:4000` (master key `sk-local-test`), using the Azure endpoint
and `AZURE_API_KEY` from `apps/litellm/.env` (gitignored; only used here). Managed identities only exist in Azure, so locally LiteLLM uses the
API key for models and a password for Postgres. If `AZURE_API_KEY` is set, it always takes
precedence over the identity, also in Azure: don't add it to the Container App.

## Updates and CI/CD

Changes in the `main` branch, specifically [`main.bicep`](main.bicep) and [`config.yaml`](config.yaml) in `apps/litellm/`, will be automatically deployed inside `rg-litellm-prod` (if all checks pass).

1. LiteLLM is pinned in `main.bicep` and `docker-compose.yml`. Twice a month Renovate opens a PR
   for the newest release at least 15 days old.
2. **CI** (`.github/workflows/litellm-ci.yml`, jobs `litellm-bicep` and `litellm-health-check`)
   builds the Bicep and starts that image with our `config.yaml` against a local Postgres
   (`docker-compose.yml`, checked by `health-check.sh`). No Azure access, no secrets.
3. If CI passes, GitHub auto-merges the PR.
4. **Deploy** (`.github/workflows/litellm-deploy.yml`) runs on main when `apps/litellm/` changes:
   logs in to Azure via OIDC as `id-litellm-github-deploy-prod`, deploys `main.bicep`, waits for the
   *new* revision to be ready and `/health/readiness` to report the database connected.
5. If that fails, it redeploys the commit that was running before (recorded as tag `commit` on the
   Container App) and opens an issue assigned to `NOTIFY_USER` (default: repo owner), so you get
   an email. main still contains the failed change: revert or fix it.

What `id-litellm-github-deploy-prod` may do: see [Identities](#identities).

### One-time GitHub setup for LiteLLM
1. Set `GITHUB_REPO: owner@ownerId/name@repoId` in `config.sops.yaml` (GitHub puts these IDs into its OIDC token), then run `mise run deploy:litellm`. Azure will trust this exact GitHub Repo to make changes in `rg-litellm-prod` (via
   `id-litellm-github-deploy-prod`). It also prints the values for step 2.
2. Settings → Environments → **New environment `litellm-production`** (the name must match):
   - Deployment branches and tags: **Selected branches → `main`**. No required reviewers.
   - **Environment secrets:** `LITELLM_GITHUB_DEPLOY_CLIENT_ID`, `AZURE_TENANT_ID`,
     `AZURE_SUBSCRIPTION_ID`, `PG_HOST`, `AZURE_API_BASE`, as printed. They grant no access by
     themselves (logging in also needs the environment's OIDC token), but as secrets they're
     masked in the logs.
   - **Environment variables:** `NOTIFY_USER` = your GitHub user name, so issues about failed
     deploys are assigned to you and you get an email. Needed in an organization repo like this
     one: without it, the issue stays unassigned. Resource names need no variables (they come
     from `names.bicep`).

The environment secrets are copies of the values in `config.sops.yaml` (see the block marked in
`config.template.yaml`) and must be kept in sync by hand: if they differ, the next GitHub deploy
reverts what `deploy.sh` set. `deploy.sh` marks every value that differs in its output.

## Notes
- Cost alerts: monthly Azure budgets of 8 € (`rg-litellm-prod`) and 1 € (`rg-litellm-secrets-prod`,
  the minimum: Azure only accepts whole amounts), in `setup.bicep`. When the actual cost exceeds the
  budget, the addresses in `BUDGET_ALERT_EMAILS` (from `config.sops.yaml`) get an email
  ([`shared/budget.bicep`](../../shared/budget.bicep)).
  Budgets only alert, they don't stop anything. Model usage is billed on the Azure AI resource,
  which is not governed by this repository: LiteLLM's key budgets limit that.
- At most one replica: budget/rate-limit state is cached per instance. Scaling out would need Redis.
- Scales to zero when idle (by default after about 5 minutes without requests): no compute cost
  then, but the first request afterwards waits for the container and LiteLLM to start (about 40 seconds for a cold start).
- Costs come from LiteLLM's price table, not Azure billing. Override per model in `config.yaml`
  if your pricing differs.
- Spend logs (one row per request, ~6 KB) are deleted after 90 days
  (`general_settings.maximum_spend_logs_retention_period` in `config.yaml`). Budgets and the daily
  usage summaries are kept; only per-request detail older than that is gone.
