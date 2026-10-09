// One-time / admin-only part of LiteLLM, in its own resource group that CI gets no rights on:
// - the managed identity LiteLLM runs as (database login, Key Vault access)
// - the Key Vault holding LiteLLM's secrets (master key, Azure OpenAI key)
// - the identity GitHub Actions deploys with (OIDC, no stored secret), and its permissions
// Kept apart because anyone who can manage these could read the secrets: directly, or by
// adding a login (federated credential) to the identity.
import { keyVaultName } from 'names.bicep'

param location string = resourceGroup().location
param identityName string
@description('Object id of the admin who writes the secrets (deploy.sh passes the signed-in user).')
param adminPrincipalId string
@description('GitHub repository (owner/name) allowed to deploy, from its "litellm-production" environment. Empty: no CI identity.')
param githubRepo string = ''
@description('Resource group of the Container App, where CI may deploy.')
param appResourceGroup string

var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  managedIdentityOperator: 'f1a07417-d97a-45cb-824c-7a7467783830'
}
var withCi = !empty(githubRepo)

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName(subscription().subscriptionId, resourceGroup().name)
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    // Soft delete is always on (90 days). Purge protection is irreversible, so left off for now.
  }
}

// LiteLLM reads its secrets.
resource identityReadsSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, identity.id, roles.keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// The admin writes them (deploy.sh, from .env).
resource adminManagesSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, adminPrincipalId, roles.keyVaultSecretsOfficer)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsOfficer)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

// --- CI: GitHub Actions logs in as this identity via OIDC ---
resource ci 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (withCi) {
  name: 'id-github-deploy-litellm'
  location: location
}

// Trusts only tokens GitHub issues for the repo's "litellm-production" environment, which in turn
// only accepts the main branch. Workflows on other branches get no Azure access.
resource ciTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = if (withCi) {
  parent: ci
  name: 'github-litellm-production'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepo}:environment:litellm-production'
    audiences: ['api://AzureADTokenExchange']
  }
}

// CI may attach id-litellm to the app (and read its client id), nothing else here:
// no Key Vault access, and no way to add logins to the identity.
resource ciAssignsIdentity 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (withCi) {
  scope: identity
  name: guid(identity.id, 'id-github-deploy-litellm', roles.managedIdentityOperator)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.managedIdentityOperator)
    principalId: withCi ? ci!.properties.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

module ciDeploysApp 'ci-access.bicep' = if (withCi) {
  name: 'ci-access'
  scope: resourceGroup(appResourceGroup)
  params: { principalId: withCi ? ci!.properties.principalId : '' }
}

output identityPrincipalId string = identity.properties.principalId
output keyVaultName string = vault.name
output ciClientId string = withCi ? ci!.properties.clientId : ''
