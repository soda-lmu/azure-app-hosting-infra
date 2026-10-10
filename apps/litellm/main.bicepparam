// Values come from .env (loaded by deploy.sh). No secrets: those live in Key Vault.
using 'main.bicep'

param appName = readEnvironmentVariable('LITELLM_APP', 'litellm')
param environmentName = readEnvironmentVariable('LITELLM_ENV', 'cae-litellm')
param secretsResourceGroup = readEnvironmentVariable('LITELLM_SECRETS_RG', 'rg-soda-litellm-secrets-prod')
param appIdentityName = readEnvironmentVariable('LITELLM_IDENTITY', 'id-litellm')
param pgHost = readEnvironmentVariable('PG_HOST')
param azureApiBase = readEnvironmentVariable('AZURE_API_BASE')
param deployedCommit = readEnvironmentVariable('DEPLOYED_COMMIT', 'unknown')
