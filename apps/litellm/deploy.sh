#!/usr/bin/env bash
# Admin deploy of LiteLLM. Safe to re-run. Run via mise (mise run deploy:litellm): it sets the
# settings from config.sops.yaml.
#  1. setup.bicep -> secrets resource group: app identity, Key Vault, GitHub Actions identity (admin-only),
#     plus the app identity's permission to call models on the Azure AI resource
#  2. secrets from config.sops.yaml -> Key Vault, if set there and changed
#  3. the identity's database on the shared server (add-app-db.sh)
#  4. main.bicep -> app resource group: Container Apps environment + app (the part CI will deploy)
#  5. custom domain: once its DNS records exist, main.bicep in stages (see customDomainStage there)
#     to add the hostname and its certificate, then to serve the domain with it
# Resource names come from names.bicep. Requires shared/postgres/deploy.sh to have run once, and
# you in the PG admin group.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
: "${SHARED_RG:?settings missing: run mise run deploy:litellm}"
: "${BUDGET_ALERT_EMAILS:?set BUDGET_ALERT_EMAILS in config.sops.yaml (email addresses for the cost alerts)}"

# Resource names, defined in names.bicep (which setup.bicep and main.bicep import).
read -r SECRETS_RG APP_RG APP_IDENTITY DB ENV CERT DOMAIN <<< "$(az bicep build -f names.bicep --stdout |
  jq -r '.variables.names | "\(.secretsResourceGroup) \(.appResourceGroup) \(.appIdentity) \(.database) \(.containerAppEnvironment) \(.customDomainCertificate) \(.customDomain)"')"

cat <<EOF
LiteLLM will be deployed into these resource groups (created if missing):
  $SECRETS_RG   identities, Key Vault (admin-only)
  $APP_RG   Container Apps environment and app
EOF
read -rp "Use these names? [y/N] " answer
[[ $answer == [yY]* ]] || { echo "Not deployed. Change the names in apps/litellm/names.bicep." >&2; exit 1; }

az group create -n "$SECRETS_RG" -l "$LOCATION" -o none
az group create -n "$APP_RG" -l "$LOCATION" -o none

# The Azure AI resource whose models LiteLLM calls, found by its endpoint's subdomain.
AI_HOST=${AZURE_API_BASE#https://}
read -r AI_ACCOUNT AI_RG <<< "$(az cognitiveservices account list \
  --query "[?properties.customSubDomainName=='${AI_HOST%%.*}'] | [0].join(' ', [name, resourceGroup])" -o tsv)"
[[ -n $AI_ACCOUNT ]] || { echo "No Azure AI resource found for $AZURE_API_BASE" >&2; exit 1; }

ME=$(az ad signed-in-user show --query id -o tsv)
SETUP=$(az deployment group create -g "$SECRETS_RG" -n litellm-setup -f setup.bicep \
  -p adminPrincipalId="$ME" githubRepo="${GITHUB_REPO:-}" \
     aiAccountName="$AI_ACCOUNT" aiResourceGroup="$AI_RG" budgetAlertEmails="$BUDGET_ALERT_EMAILS" \
  --query "[properties.outputs.appIdentityPrincipalId.value, properties.outputs.keyVaultName.value, properties.outputs.githubIdentityClientId.value]" -o tsv)
read -r APP_PRINCIPAL_ID KEYVAULT GITHUB_CLIENT_ID <<< "$(echo $SETUP)"

# Writes a secret if its value is set in config.sops.yaml and differs from Key Vault. Retries while the
# role assignment from setup.bicep is still propagating (can take a few minutes).
# Mode "once": only written if missing; a different existing value stops the script.
put_secret() {
  local name=$1 value=$2 mode=${3:-update} current='' state=unreachable
  [[ -n $value ]] || return 0
  for _ in $(seq 30); do
    if current=$(az keyvault secret show --vault-name "$KEYVAULT" -n "$name" --query value -o tsv 2>&1); then state=exists; break; fi
    if [[ $current == *SecretNotFound* ]]; then current=; state=missing; break; fi
    sleep 10
  done
  [[ $state == unreachable ]] && { echo "Key Vault: can't read $name: $current" >&2; exit 1; }
  [[ $current == "$value" ]] && return 0
  if [[ $mode == once && $state == exists ]]; then
    echo "Key Vault: $name is already set and differs from config.sops.yaml. Not changed: changing it makes" >&2
    echo "everything LiteLLM encrypted in its database unreadable. Fix config.sops.yaml or remove the value there." >&2
    exit 1
  fi
  az keyvault secret set --vault-name "$KEYVAULT" -n "$name" --file <(printf %s "$value") -o none
  echo "Key Vault: updated $name"
}
put_secret litellm-master-key "${LITELLM_MASTER_KEY:-}"
put_secret litellm-salt-key "${LITELLM_SALT_KEY:-}" once

"$ROOT/shared/postgres/add-app-db.sh" "$DB" "$APP_IDENTITY" "$APP_PRINCIPAL_ID" >/dev/null

# Recorded on the app, so CI can roll back to it. "-dirty": deployed with uncommitted changes.
DEPLOYED_COMMIT=$(git rev-parse HEAD)$([[ -z $(git status --porcelain -- .) ]] || echo -dirty)
export DEPLOYED_COMMIT
# Deploys main.bicep; $1: custom domain stage (none, hostname, bound). Prints the outputs
# url, fqdn and domainVerificationId. Assign the result (OUT=$(...)), so a failure stops the script.
deploy_app() {
  LITELLM_CUSTOM_DOMAIN_STAGE=$1 az deployment group create -g "$APP_RG" -n litellm -p main.bicepparam \
    --query "properties.outputs.[url.value, fqdn.value, domainVerificationId.value]" -o tsv | xargs
}
# Provisioning state of the custom domain's certificate; empty if it (or the environment) is missing.
cert_state() {
  az containerapp env certificate list -g "$APP_RG" -n "$ENV" --managed-certificates-only \
    --query "[?name=='$CERT'] | [0].properties.provisioningState" -o tsv 2>/dev/null || true
}

if [[ -z $DOMAIN || $(cert_state) == Succeeded ]]; then
  OUT=$(deploy_app bound)
else
  # The app only accepts the hostname once DNS points to it and proves ownership. So: deploy
  # without the domain (gives the record values), check DNS, then the stages hostname and bound.
  OUT=$(deploy_app none)
  read -r URL FQDN VERIFICATION_ID <<< "$OUT"
  cname=$(dig +short CNAME "$DOMAIN")
  if [[ ${cname,,} != "${FQDN,,}." || $(dig +short TXT "asuid.$DOMAIN") != *"$VERIFICATION_ID"* ]]; then
    echo "Custom domain: not set up yet. Create these DNS records, then re-run deploy.sh:"
    echo "  $DOMAIN  CNAME  $FQDN"
    echo "  asuid.$DOMAIN  TXT  $VERIFICATION_ID"
  else
    OUT=$(deploy_app hostname)
    echo "Custom domain: waiting for the certificate of $DOMAIN (usually a few minutes)"
    for _ in $(seq 90); do # up to 15 minutes
      state=$(cert_state)
      [[ $state == Pending || -z $state ]] || break
      sleep 10
    done
    if [[ $state != Succeeded ]]; then
      echo "Custom domain: certificate $CERT is '$state'. Check the DNS records, then delete it" >&2
      echo "(az containerapp env certificate delete -g $APP_RG -n $ENV -c $CERT) and re-run." >&2
      exit 1
    fi
    OUT=$(deploy_app bound)
  fi
fi
read -r URL _ <<< "$OUT"
echo "Deployed: $URL  (check: curl $URL/health/readiness)"

if [[ -n ${GITHUB_CLIENT_ID:-} ]]; then
  # The values GitHub must have. Compared with config.sops.yaml, where the same values are kept in sync by hand.
  github_secret() {
    local note=''
    [[ ${!1:-} == "$2" ]] || note="   <- differs from config.sops.yaml, update it there too"
    echo "  $1=$2$note"
  }
  echo
  echo "GitHub: Create GitHub environment 'litellm-production' for branch main and add the following (low-sensitive) secrets." 
  echo "GitHub: Configure that only branch main can deploy to it."
  echo "GitHub: Settings -> Environments -> litellm-production. Keep in sync with config.sops.yaml."
  echo "Environment secrets:"
  github_secret PG_HOST "$PG_HOST"
  github_secret AZURE_API_BASE "$AZURE_API_BASE"
  github_secret AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"
  github_secret AZURE_SUBSCRIPTION_ID "$(az account show --query id -o tsv)"
  github_secret LITELLM_GITHUB_DEPLOY_CLIENT_ID "$GITHUB_CLIENT_ID"

fi
