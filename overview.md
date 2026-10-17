# Overview

CI/CD is a core DevOps practice. This repo uses it to deploy and update apps automatically,
starting with LiteLLM. The main motivation was to implement this process end to end. What does it mean for the app's security if no human is involved in deployment?

```
            trigger          CI             merge          CD
Standard:   developer push → build → test → human review → staging → production
This repo:  Renovate PR    → build → test → auto-merge   → production → health check (rollback if it fails)
```

- **Renovate:** a bot that watches dependencies (the LiteLLM image, GitHub Actions) and opens a
  PR when a new version is out.
- **CI (Continuous Integration):** every PR is built and checked automatically (here: Bicep
  builds, the new image starts and reaches its database) before it can be merged.
- **CD (Continuous Deployment):** every merge to `main` goes to production automatically, with a
  health check and rollback, and no human step in between.

## Central motives

### 1. CI with automated updates
The apps should stay current without anyone watching. The Renovate bot opens a PR when a new LiteLLM
release is at least 15 days old (twice a month, at night). CI checks it: if the Bicep builds, if the
new image starts and reaches its database. If CI passes, GitHub merges the
PR, and the merge deploys to Azure. The deploy checks the new revision's health and rolls back to
the previous version if it fails, then opens an issue. A human only steps in when something breaks.

### 2. Strong security, while keeping everything in git
Everything that describes the setup is in the repo: infrastructure as Bicep, scripts, CI, and
even the settings. Security features:
- **One identity system, no stored keys or passwords.** Every login (app, CI, Postgres, Key Vault,
  SOPS) goes through Microsoft Entra, so access is granted and revoked in one place. The app uses
  its managed identity; GitHub Actions logs in to Azure with OIDC, only from the `main` branch.
- **Least privilege by resource group.** CI may deploy the app, but can't touch the admin-only
  resource group with the identities and the Key Vault holding the app's secrets.
- **Settings committed, but encrypted.** `config.sops.yaml` is encrypted with SOPS; only the
  admin group can decrypt it via a Key Vault key, or with a post-quantum age key as offline backup.
- **Secrets stay out of shells and logs.** mise decrypts the settings per task, not into your
  shell; GitHub masks its environment secrets.

### 3. Cheap
Everything is sized small, and every resource group has a monthly budget that emails the admins
when exceeded (alerts only, nothing is stopped):

| Resource group | Budget | Main cost |
|---|---|---|
| Shared (`SHARED_RG`) | 19 € | PostgreSQL server (smallest burstable size), SOPS Key Vault |
| `rg-litellm-prod` | 8 € | Container App, scales to zero when idle |
| `rg-litellm-secrets-prod` | 1 € | Key Vault, a few cents |

The PostgreSQL server is the largest fixed cost, and it is meant to be **shared**: further apps get
their own database and login role on it instead of their own
server. Each additional app then mainly adds a Container App that scales to zero.

Model usage is billed on the existing Azure AI resource, outside these budgets; LiteLLM's
per-key budgets limit it.

### 4. Declarative
The repo describes *what* should exist, not the steps to get there. Azure compares the
description with what is running and changes only the difference. This is what makes automated
updates manageable:
- **One home for each kind of thing.** Infrastructure, identities and roles in the Bicep files
  (names in `names.bicep`), settings in `config.sops.yaml`, LiteLLM's models in
  `apps/litellm/config.yaml`, decryption rights in `.sops.yaml`, admin tasks in `mise.toml`,
  update rules in `renovate.json`, CI and deploy in `.github/workflows/`. Whatever you want to
  change, there is one file to edit.
- **A change is a diff.** An update, a new model or a new role is an edit to a file, reviewed and
  checked in a PR like any code. Renovate's LiteLLM update is literally a one-line version bump.
- **Repeatable.** Deploying the same files again changes nothing, so every deploy can simply be
  re-run, and a re-run also resets manual portal changes to anything the files declare.
- **Rollback is a redeploy.** The previous state is just an older commit; the deploy workflow
  rolls back by deploying that commit's files.
- **Reproducible.** The files plus `config.sops.yaml` rebuild the setup, e.g. in another
  subscription (plus the manual steps under Shortcomings), and git history shows who changed
  what and when.

## Architecture

```
               GitHub (repo, CI, Renovate)
                 │  OIDC login, only from main
                 ▼
 ┌────────────── Azure ─────────────────────────────────────────────┐
 │ rg-litellm-prod            Container App: LiteLLM proxy          │
 │   (routine deploys)          │ managed identity                  │
 │                              ├──► Key Vault: master + salt key   │
 │                              ├──► Azure AI models (no API key)   │
 │                              └──► shared PostgreSQL (Entra login)│
 │ rg-litellm-secrets-prod    identities + Key Vault (admin only)   │
 │ SHARED_RG                  PostgreSQL server + SOPS Key Vault    │
 └──────────────────────────────────────────────────────────────────┘
```

- **LiteLLM** (`apps/litellm`): a proxy in front of Azure AI models that hands out
  budget-limited keys. Split into an admin part (`apps/litellm/setup.bicep`: identities, Key Vault, roles) and
  a routine part (`apps/litellm/main.bicep`: the app), which CI may deploy.
- **Shared PostgreSQL** (`shared/postgres`): one server, but separate databases and login role for each app.
- **SOPS key** (`shared/sops`): a Key Vault key that encrypts the repo's settings,
  `config.sops.yaml`. Only the admin group can use it.

**Two ways to deploy:**
- *Admin, rarely:* `mise run deploy:…` from a laptop. Creates everything, including identities,
  roles and secrets.
- *Automatic, routinely:* a merge to `main` runs the deploy workflow. It only touches the app,
  checks the new revision's health, and rolls back if needed.

## Who does what

Each actor has its own identity and only the rights it needs. None of them holds a stored
password or key: Azure identities get short-lived Entra tokens instead.

| Actor | Identity | Does | May not |
|---|---|---|---|
| **Renovate** (GitHub app) | its GitHub app | Opens PRs for new LiteLLM images and Actions versions | Merge, or reach Azure |
| **CI** (`litellm-ci.yml`) | none | Builds the Bicep, starts the image with Docker Compose and checks its health | Reach Azure (dummy values only) |
| **GitHub auto-merge** | GitHub | Merges a PR once the required checks pass | Skip the checks |
| **Deploy** (`litellm-deploy.yml`) | `id-litellm-github-deploy-prod`, via OIDC | Deploys `main.bicep` to `rg-litellm-prod`, checks health, rolls back, opens an issue | Read secrets, touch the admin resource group |
| **LiteLLM** (Container App) | `id-litellm-prod`, a managed identity | Reads its secrets from Key Vault, calls the AI models, uses its database | Change Azure resources, see other apps' databases |
| **Admin** (you) | your Entra account, in `PG_ENTRA_ADMIN_GROUP` | Runs the `mise run deploy:…` tasks: creates identities, roles, secrets; decrypts `config.sops.yaml` | — |

**How the deploy logs in without a secret (OIDC):** GitHub issues the workflow a short-lived token
that says "repo X, environment `litellm-production`". Azure trusts exactly that statement for
`id-litellm-github-deploy-prod` (a federated credential), and the environment only accepts the
`main` branch. Workflows on other branches or forks get no Azure access.

**How the app logs in (managed identity):** Azure attaches `id-litellm-prod` to the Container App
and hands it tokens directly. Nobody can use that identity from outside, so there's nothing to
leak. The deploy may attach it to the app, but not add logins to it.

## Tech stack

| Group | Piece | Role |
|---|---|---|
| **Runs in Azure** | LiteLLM | The app: proxy with budget-limited keys in front of Azure AI models |
| | Azure Container Apps | Runs LiteLLM; scales to zero, managed TLS for the custom domain |
| | Azure Database for PostgreSQL | Shared database server, one database per app |
| | Azure Key Vault | App secrets; key for SOPS |
| | Microsoft Entra ID | All identities and logins: managed identities, GitHub OIDC, admins |
| **Describes Azure** | Bicep | All resources, identities and roles as code |
| | Bash scripts | Admin steps Bicep can't do (database roles, DNS checks, staged rollout) |
| **Automates updates** | Renovate | Pins and updates the LiteLLM image and the Actions |
| | GitHub Actions | CI (Bicep build, health check) and deploy with rollback |
| **Admin tooling** | SOPS + age | Encrypted settings in git; Key Vault by default, post-quantum age key as backup |
| | mise | Runs the admin tasks and hands them the decrypted settings |
| | Docker Compose | Local test with the same image and config as Azure |

## Shortcomings

The code should be relatively simple, running it should cost as little as possible. This meant some compromises.

### Performance
- **Slow first request.** To save money, the app scales to zero after about 5 minutes without
  requests. The next request waits about 40 seconds while LiteLLM starts.
- **Does not scale for very high load.** The app runs as a single instance. Several instances
  wouldn't share their count of each key's spending, so a key could exceed its budget. Sharing
  would need an extra service (Redis).

### Costs
- **Model usage is outside every budget.** The largest variable cost, calling the AI models, is
  billed on the existing Azure AI resource, which this repo doesn't manage. Only LiteLLM's
  per-key budgets limit it, and LiteLLM calculates costs from its own price table, not from
  Azure's bill: a model missing from that table needs a price in `apps/litellm/config.yaml`, or its usage is counted wrong. Calls that bypass LiteLLM aren't counted at all.
- **Fixed costs even when idle.** The app scales to zero, but the PostgreSQL server runs around
  the clock (Azure restarts a stopped server after 7 days). It only pays off once more apps share
  it.
- **Budgets only warn, and late.** Each budget sends a single email once the actual cost has
  exceeded it: no early warning (e.g. at 80 %), and Azure's cost data can lag by up to a day, so
  the alert comes after the money is spent. Nothing stops spending. In practice this matters
  little: the resources here have a fixed size (one small Postgres server, at most one app
  instance), so their cost can't suddenly spike; unusually high costs aren't expected.

### Security and access
- **Merging is deploying.** Anyone with write access can merge into `main` (0 approvals) and so
  deploy to production. There is no staging environment.
- **Postgres is reachable from all of Azure.** The firewall allows every Azure service, and a
  password admin exists. A private network would be safer, but costs more and needs a rebuild.
- **One group, two powers.** `PG_ENTRA_ADMIN_GROUP` is both Postgres admin and SOPS key user;
  you can't grant one without the other (though this is on purpose, so that new admins can get all rights with a single click).

### Reliability
- **Updates migrate the production database directly.** A new LiteLLM version updates its
  database schema when it starts. With no staging environment, that migration runs first on
  production data. If the new version fails, the automatic rollback restores the old app, but not
  the old schema, which the old version may not handle. The fallback is a point-in-time restore
  of the database (within `PG_BACKUP_RETENTION_DAYS`), by hand. A staging app with its own
  database on the shared server would catch most of this at almost no cost.

### Admin effort
- **Settings live in two places.** The deploy workflow reads five values from GitHub secrets,
  which must be kept in sync with `config.sops.yaml` by hand. There are better way to set this up.
- **Not everything is declarative.** Bash scripts handle what Bicep can't (database roles, DNS
  checks, the staged certificate rollout). And removing something from Bicep doesn't remove it
  from Azure: deleted resources and roles must be cleaned up by hand.
- **Manual admin steps remain.** First install, DNS records, the SOPS bootstrap and the age
  backup key are all done by hand, and some admin paths (e.g. reading an app's tables) are
  untested.
- **Many tools on the admin's machine.** `az`, `mise`, `sops`, Docker, `jq`, `dig`, plus quirks
  such as `AZURE_TOKEN_CREDENTIALS` outside Azure.

## Could more be declarative?

Possible paths to improve the codebase:
- **Azure Deployment Stacks:** the same Bicep, but resources and roles removed from the files are
  also deleted in Azure.
- **More in Bicep:** resource groups, the Entra admin group (Microsoft Graph extension), and the
  DNS records if the zone moves to Azure DNS.
- **GitHub settings** (environment, secrets, rulesets) with the Terraform/OpenTofu GitHub
  provider. This would also fill the GitHub secrets from `config.sops.yaml` automatically.

Some steps stay imperative: the database roles (SQL), the staged certificate rollout, the
rollback logic and the first SOPS bootstrap. Moving everything to OpenTofu/Terraform would cover
the most, but adds a state file to store safely and is only worth it with more apps.
