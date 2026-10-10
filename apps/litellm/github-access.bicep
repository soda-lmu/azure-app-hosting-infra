// Gives the GitHub Actions identity (names.githubIdentity) Contributor access 
// on the app resource group (names.appResourceGroup). No secrets are stored here.
param principalId string

var contributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource githubDeploysApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, contributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributor)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
