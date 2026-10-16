// Key Vault with the key that encrypts the repo's secrets with SOPS (see .sops.yaml).
// Members of the admin group (PG_ENTRA_ADMIN_GROUP) may encrypt and decrypt with it; nobody else,
// in particular no app or GitHub Actions identity.
param location string = resourceGroup().location
@description('Object id of the Entra group whose members may use the key (deploy.sh looks it up).')
param adminGroupObjectId string

var keyVaultCryptoUser = '12338af0-0e69-4776-bea7-57ae8d297424'

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  // Globally unique, stable per resource group (max 24 chars: 8 + 13-char hash).
  name: 'kv-sops-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    // Soft delete is always on (90 days). Purge protection is irreversible, so left off for now.
  }
}

// Created once; re-deploying doesn't replace or update it (keyOps included). Deleting it leaves
// only the age backup key to decrypt the encrypted files.
resource sopsKey 'Microsoft.KeyVault/vaults/keys@2024-11-01' = {
  parent: vault
  name: 'sops-config'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: ['encrypt', 'decrypt']
  }
}

resource adminsUseKey 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sopsKey
  name: guid(sopsKey.id, adminGroupObjectId, keyVaultCryptoUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoUser)
    principalId: adminGroupObjectId
    principalType: 'Group'
  }
}

// Without version: sops then uses the latest one.
output keyUrl string = sopsKey.properties.keyUri
