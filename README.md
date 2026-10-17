# Azure apps: shared PostgreSQL and LiteLLM

Infrastructure as Bicep, deployed with small scripts; LiteLLM is updated automatically via
Renovate and GitHub Actions. Why it is built this way, and where it falls short:
[overview.md](overview.md).

| Part | What | README |
|---|---|---|
| `shared/postgres/` | PostgreSQL 18 server shared by several apps, one database per app | [shared/postgres/README.md](shared/postgres/README.md) |
| `shared/sops/` | Key Vault key for SOPS: secret files committed encrypted, e.g. the settings `config.sops.yaml` | [shared/sops/README.md](shared/sops/README.md) |
| `apps/litellm/` | LiteLLM proxy with budget-limited keys in front of Azure OpenAI | [apps/litellm/README.md](apps/litellm/README.md) |

## Getting started
1. Install [mise](https://mise.jdx.dev), `sops` and the `az` CLI, then `mise trust` in the repo.
2. The settings are in `config.sops.yaml`, encrypted with SOPS (template: `config.template.yaml`).
   The deploy scripts get them from mise: `mise run <task>` (list: `mise tasks`, defined in
   `mise.toml`). To create the file and its key, see [shared/sops](shared/sops/README.md).
3. Deploy the [shared PostgreSQL server](shared/postgres/README.md#deploy), then
   [LiteLLM](apps/litellm/README.md#deploy).

`.env` files are only for the local docker compose test (`apps/litellm/.env`).

## Repository rules
Needed for automatic updates. Private repos need GitHub Pro, Team or Enterprise for rulesets.

1. Install the [Renovate app](https://github.com/apps/renovate) for this repo only. It opens PRs
   at night (01:00–07:00 Berlin time), merged automatically once CI passes:
   - LiteLLM: on the 1st and 15th, releases at least 15 days old.
   - GitHub Actions: one PR on the 1st, pinned to commit hashes. Major versions wait for review.
2. Settings → General → **Allow auto-merge**.
3. Settings → Rules → Rulesets → **`main: quality`** on the default branch, empty bypass list:
   - Require a pull request before merging (0 approvals)
   - Require status checks: `litellm-bicep`, `litellm-health-check`, `postgres-bicep`
   - Block force pushes, restrict deletions

   No *Restrict updates* rule: it would also block auto-merge.
4. **Everyone with write access can merge into main, which deploys to production.**
   - Give write access only to people you trust with production; others get *Read* or *Triage*
     and send PRs from a fork.
   - The org's base permission must not be *Write* (org Settings → Member privileges).
   - Keep the admin role to yourself: admins can change these rules.
