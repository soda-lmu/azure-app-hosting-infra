// Names derived the same way by setup.bicep and main.bicep.

@export()
@description('Globally unique Key Vault name (max 24 chars), stable per subscription and resource group.')
func keyVaultName(subscriptionId string, resourceGroupName string) string =>
  'kv-litellm-${uniqueString(subscriptionId, resourceGroupName)}'
