// Values of this installation, from .env (loaded by deploy.sh) or the GitHub environment secrets.
// Resource names come from names.bicep. No secrets: those live in Key Vault.
using 'main.bicep'

param pgHost = readEnvironmentVariable('PG_HOST')
param azureApiBase = readEnvironmentVariable('AZURE_API_BASE')
param deployedCommit = readEnvironmentVariable('DEPLOYED_COMMIT', 'unknown')
