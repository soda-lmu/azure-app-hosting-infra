// One-time / admin-only part of LiteLLM, in its own resource group that GitHub Actions gets no
// rights on. Overview of the identities and their permissions: README.md, "Identities".
// - appIdentity (id-litellm): the managed identity LiteLLM runs as (database login, Key Vault
//   access, calling models on the Azure AI resource without an API key)
// - the Key Vault holding LiteLLM's secrets (master key, salt key)
// - githubIdentity (id-github-deploy-litellm): what GitHub Actions deploys with (OIDC, no stored
//   secret), and its permissions
// Kept apart because anyone who can manage these could read the secrets: directly, or by
// adding a login (federated credential) to an identity.
import { keyVaultName } from 'names.bicep'

param location string = resourceGroup().location
param appIdentityName string
@description('Object id of the admin who writes the secrets (deploy.sh passes the signed-in user).')
param adminPrincipalId string
@description('GitHub repository (owner/name) allowed to deploy, from its "litellm-production" environment. Empty: no GitHub Actions identity.')
param githubRepo string = ''
@description('Resource group of the Container App, where GitHub Actions may deploy.')
param appResourceGroup string
@description('Azure AI resource whose models LiteLLM calls, and its resource group (deploy.sh looks both up).')
param aiAccountName string
param aiResourceGroup string

var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  managedIdentityOperator: 'f1a07417-d97a-45cb-824c-7a7467783830'
}
var withGithub = !empty(githubRepo)

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appIdentityName
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
resource appReadsSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, appIdentity.id, roles.keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: appIdentity.properties.principalId
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

// --- GitHub Actions logs in as this identity via OIDC (id-github-deploy-litellm) ---
resource githubIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (withGithub) {
  name: 'id-github-deploy-litellm'
  location: location
}

// Trusts only tokens GitHub issues for the repo's "litellm-production" environment, which in turn
// only accepts the main branch. Workflows on other branches get no Azure access.
resource githubTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = if (withGithub) {
  parent: githubIdentity
  name: 'github-litellm-production'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepo}:environment:litellm-production'
    audiences: ['api://AzureADTokenExchange']
  }
}

// GitHub Actions may attach id-litellm to the app (and read its client id), nothing else here:
// no Key Vault access, and no way to add logins to the identity.
resource githubAttachesAppIdentity 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (withGithub) {
  scope: appIdentity
  name: guid(appIdentity.id, 'id-github-deploy-litellm', roles.managedIdentityOperator)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.managedIdentityOperator)
    principalId: withGithub ? githubIdentity!.properties.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

// Modules let us grant permissions in other resource groups (GitHub Actions deploys the app, LiteLLM calls Azure AI) without
// having to give this resource group any rights on those other groups.
module githubDeploysApp 'github-access.bicep' = if (withGithub) {
  name: 'github-access'
  scope: resourceGroup(appResourceGroup)
  params: { principalId: withGithub ? githubIdentity!.properties.principalId : '' }
}

module appCallsModels 'ai-access.bicep' = {
  name: 'ai-access'
  scope: resourceGroup(aiResourceGroup)
  params: { aiAccountName: aiAccountName, principalId: appIdentity.properties.principalId }
}

output appIdentityPrincipalId string = appIdentity.properties.principalId
output keyVaultName string = vault.name
output githubIdentityClientId string = withGithub ? githubIdentity!.properties.clientId : ''
