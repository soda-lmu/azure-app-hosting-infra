# Azure apps: shared PostgreSQL and LiteLLM

Infrastructure as Bicep, deployed with small scripts; LiteLLM is updated automatically via
Renovate and GitHub Actions.

| Part | What | README |
|---|---|---|
| `shared/postgres/` | PostgreSQL 18 server shared by several apps, one database per app | [shared/postgres/README.md](shared/postgres/README.md) |
| `apps/litellm/` | LiteLLM proxy with budget-limited keys in front of Azure OpenAI | [apps/litellm/README.md](apps/litellm/README.md) |

## Getting started
1. `cp .env.example .env` and fill it in. `.env` is gitignored and is the only place for local
   secrets; the `.bicepparam` files and scripts read it.
2. Deploy the [shared PostgreSQL server](shared/postgres/README.md#deploy), then
   [LiteLLM](apps/litellm/README.md#deploy).

## Repository rules
Apply to the whole repo; needed for automatic updates. Private repos need GitHub Pro, Team or
Enterprise for rulesets.

1. Install the [Renovate app](https://github.com/apps/renovate) for this repo only.
   `renovate.json`: every update waits 18 days, GitHub Actions are pinned to commit hashes, only
   the LiteLLM image is merged automatically.
2. Settings → General → **Allow auto-merge**.
3. Settings → Rules → Rulesets, both targeting the default branch:
   - **`main: who can merge`**: rule *Restrict updates*. Bypass list: *Repository admin* and the
     *Renovate* app. Everyone else with write access can open PRs but not merge.
   - **`main: quality`**: *Require a pull request before merging* (0 approvals), *Require status
     checks to pass* (`litellm-bicep`, `litellm-health-check`, `postgres-bicep`), *Block force
     pushes*, *Restrict deletions*. Bypass list: empty, so CI is required for you and Renovate too.
4. Keep the admin role to yourself: admins can change these rules.
