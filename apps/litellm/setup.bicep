// One-time / admin-only part to set up LiteLLM.
//  This runs inside the secretsResourceGroup, so that GitHub Actions gets no rights on.
// Kept apart from appResourceGroup because anyone who can manage these could read the secrets: directly, or by
// adding a login (federated credential) to an identity.
//  
//Overview of the identities and their permissions: README.md, "Identities".
// - appIdentity: the managed identity LiteLLM runs as (database login, Key Vault access, calling
//   models on the Azure AI resource without an API key)
// - the Key Vault holding LiteLLM's secrets (master key, salt key)
// - githubIdentity: what GitHub Actions deploys with (OIDC, no stored
//   secret), and its permissions

import { names, keyVaultName } from 'names.bicep'

param location string = resourceGroup().location
@description('Object id of the admin who writes the secrets (deploy.sh passes the signed-in user).')
param adminPrincipalId string
@description('GitHub repository (owner/name) allowed to deploy, from its "litellm-production" environment. Empty: no GitHub Actions identity.')
param githubRepo string = ''
@description('Azure AI resource whose models LiteLLM calls, and its resource group (deploy.sh looks both up).')
param aiAccountName string
param aiResourceGroup string
@description('Comma-separated email addresses for the cost alerts (BUDGET_ALERT_EMAILS in .env).')
param budgetAlertEmails string

var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  managedIdentityOperator: 'f1a07417-d97a-45cb-824c-7a7467783830'
}
var withGithub = !empty(githubRepo)

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.appIdentity
  location: location
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName(subscription().subscriptionId, names.secretsResourceGroup)
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

// --- GitHub Actions logs in as this identity via OIDC ---
resource githubIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (withGithub) {
  name: names.githubIdentity
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

// GitHub Actions may attach the app identity to the app (and read its client id), nothing else here:
// no Key Vault access, and no way to add logins to the app identity.
resource githubAttachesAppIdentity 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (withGithub) {
  scope: appIdentity
  name: guid(appIdentity.id, names.githubIdentity, roles.managedIdentityOperator)
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
  scope: resourceGroup(names.appResourceGroup)
  params: { principalId: withGithub ? githubIdentity!.properties.principalId : '' }
}

module appCallsModels 'ai-access.bicep' = {
  name: 'ai-access'
  scope: resourceGroup(aiResourceGroup)
  params: { aiAccountName: aiAccountName, principalId: appIdentity.properties.principalId }
}

// Monthly cost alerts (EUR), see shared/budget.bicep.
var budgetContacts = map(split(budgetAlertEmails, ','), email => trim(email))

module secretsBudget '../../shared/budget.bicep' = {
  name: 'budget'
  // 0.20 € wanted; 1 € is the minimum
  params: { name: 'budget-${names.secretsResourceGroup}', amount: 1, timeGrain: 'Monthly', contactEmails: budgetContacts }
}

module appBudget '../../shared/budget.bicep' = {
  name: 'budget'
  scope: resourceGroup(names.appResourceGroup)
  params: { name: 'budget-${names.appResourceGroup}', amount: 8, timeGrain: 'Monthly', contactEmails: budgetContacts }
}

output appIdentityPrincipalId string = appIdentity.properties.principalId
output keyVaultName string = vault.name
output githubIdentityClientId string = withGithub ? githubIdentity!.properties.clientId : ''
