// Azure resource names of LiteLLM: the one place they're defined (not secret). setup.bicep and
// main.bicep import them; deploy.sh and litellm-deploy.yml read them from the compiled file
// (az bicep build). To use other names, change them here. deploy.sh asks you to confirm the
// resource groups before deploying.

@export()
var names = {
  // Container Apps environment and app; GitHub Actions deploys here.
  appResourceGroup: 'rg-litellm-prod'
  // Identities and Key Vault; admin-only.
  secretsResourceGroup: 'rg-litellm-secrets-prod'
  containerAppEnvironment: 'cae-litellm-prod'
  containerApp: 'ca-litellm-prod'
  logWorkspace: 'log-litellm-prod'
  // Managed identity LiteLLM runs as (Postgres login, Key Vault, Azure AI).
  appIdentity: 'id-litellm-prod'
  // Identity GitHub Actions deploys with.
  githubIdentity: 'id-litellm-github-deploy-prod'
  // Database on the shared PostgreSQL server.
  database: 'litellm_db'
}

@export()
@description('Globally unique Key Vault name (max 24 chars: 11 + 13-char hash), stable per subscription and resource group.')
func keyVaultName(subscriptionId string, resourceGroupName string) string =>
  'kv-litellm-${uniqueString(subscriptionId, resourceGroupName)}'
