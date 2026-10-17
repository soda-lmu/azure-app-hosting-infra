#!/usr/bin/env bash
# Usage: domain-stage.sh [names.bicep]   (default: the one next to this script)
# Picks main.bicep's customDomainStage from the custom domain's managed certificate. Used by
# deploy.sh and litellm-deploy.yml (deploy and rollback), so both decide the same way.
# Prints "<stage> <reason>":
#   bound     reason Succeeded (certificate issued for customDomain), or no-domain (empty
#             customDomain; main.bicep then deploys none)
#   hostname  reason Pending: certificate being issued; it needs the hostname to stay on the app
#   none      reason missing, other-domain (certificate is for another hostname: rename
#             customDomainCertificate), or a failed provisioning state
# Fails if Azure can't be asked: guessing 'none' would remove a working domain from the app.
set -euo pipefail
NAMES_FILE=${1:-$(dirname "$0")/names.bicep}
names=$(az bicep build -f "$NAMES_FILE" --stdout | jq -r '.variables.names |
  "\(.appResourceGroup)\n\(.containerAppEnvironment)\n\(.customDomainCertificate // "")\n\(.customDomain // "" | ascii_downcase)"')
# Older commits lack the domain names: their empty lines are cut off, so read reaches the end.
{ read -r RG; read -r ENV; read -r CERT; read -r DOMAIN; } <<< "$names" || true

[[ -n $DOMAIN ]] || { echo "bound no-domain"; exit 0; }
# Before the first deploy there's no environment, and so no certificate.
# Assigned first: inside [[ ]], a failed az call wouldn't stop the script.
envs=$(az containerapp env list -g "$RG" --query "[?name=='$ENV'].name" -o tsv)
[[ -n $envs ]] || { echo "none missing"; exit 0; }
cert=$(az containerapp env certificate list -g "$RG" -n "$ENV" --managed-certificates-only \
  --query "[?name=='$CERT'] | [0].properties" -o json)
state=$(jq -r '.provisioningState // "missing"' <<< "${cert:-null}")
subject=$(jq -r '.subjectName // "" | ascii_downcase' <<< "${cert:-null}")

# Both lowercased: hostnames are case-insensitive.
if [[ $state != missing && $subject != "$DOMAIN" ]]; then echo "none other-domain"
elif [[ $state == Succeeded ]]; then echo "bound $state"
elif [[ $state == Pending ]]; then echo "hostname $state"
else echo "none $state"
fi
