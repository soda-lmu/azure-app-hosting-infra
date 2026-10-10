// Gives the GitHub Actions identity (id-github-deploy-litellm) Contributor on the app resource group (deployed by setup.bicep as a
// module, because that resource group is a different scope).
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
