// Lets LiteLLM's managed identity call models on the Azure AI resource with Entra tokens instead
// of an API key (scoped to the AI resource's resource group).

param aiAccountName string
param principalId string

var openAiUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// Find AI foundry ressource
resource aiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aiAccountName
}

resource litellmCallsModels 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiAccount
  name: guid(aiAccount.id, principalId, openAiUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUser)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
