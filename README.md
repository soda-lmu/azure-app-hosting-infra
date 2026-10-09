# LiteLLM on Azure Container Apps

LiteLLM proxy with budget-limited virtual keys in front of Azure OpenAI, backed by a
**shared** PostgreSQL Flexible Server that other apps can use too.

```
rg-shared-data   pg-shared-…        PostgreSQL 16, one database + role per app
rg-litellm       cae-litellm        Container Apps environment
                 litellm            LiteLLM proxy (1 replica), defined in apps/litellm/app.yaml
```

## Prerequisites
`az` CLI (logged in: `az login`), Docker (used to run `psql`), `envsubst` (package `gettext`).

## Setup
1. `cp .env.example .env` and fill it in. Generate passwords with `openssl rand -hex 24`.
2. Edit `apps/litellm/config.yaml`: one entry per Azure OpenAI deployment, with an explicit price if the model is newer than the pinned LiteLLM.
3. Create the shared server (once): `shared/postgres/create-server.sh`
4. Deploy LiteLLM (also for every later change): `apps/litellm/deploy.sh`

`deploy.sh` creates the resource group, environment and the `litellm` database/role on
first run, then renders `app.yaml` with secrets from `.env` and creates or updates the app.

## Use
```bash
curl https://<fqdn>/health/readiness
curl -X POST https://<fqdn>/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["gpt-6-luna"],"max_budget":50,"budget_duration":"30d"}'
```

## Shared PostgreSQL
- Add another app's database: `shared/postgres/add-app-db.sh <app> <password>`.
  Each app gets its own login role owning its own database; other roles can't connect to it.
- Browse it with pgAdmin/DBeaver/psql at `<PG_SERVER>.postgres.database.azure.com:5432`,
  `sslmode=require`. The firewall allows Azure services and the IP that ran `create-server.sh`;
  add your current IP if it changed:
  `az postgres flexible-server firewall-rule create -g rg-shared-data -n <server> --rule-name me --start-ip-address <ip> --end-ip-address <ip>`
- Going private later: add a private endpoint and VNet-integrate the Container Apps
  environments, then remove the "allow Azure services" rule. No server rebuild needed.
- Don't stop the server to save money: other apps depend on it, and LiteLLM can't enforce
  budgets without it.

## Local test
`cd apps/litellm && docker compose up` gives the same image and config on `localhost:4000`
(master key `sk-local-test`).

## Updates
LiteLLM is pinned in `app.yaml`. Renovate (`renovate.json`) proposes new versions only
after they are 18 days old, updating `app.yaml` and `docker-compose.yml` in one PR.
Automerge is off until a CI health check exists.

## Notes
- Exactly one replica: budget/rate-limit state is cached per instance. Scaling out needs Redis.
- Costs come from LiteLLM's price table, not Azure billing. Override per model in `config.yaml`
  if your pricing differs.
