// Shared PostgreSQL Flexible Server, used by several apps.
// PostgreSQL and Microsoft Entra authentication: admins are the members of an Entra group,
// plus a password admin for tools without Entra login (e.g. DBeaver Community).
// Apps log in with managed identities, each with its own database (add-app-db.sh).
param location string = resourceGroup().location
param serverName string
param skuName string = 'Standard_B1ms'
param adminGroupName string
param adminGroupObjectId string
param pgAdminUser string
@secure()
param pgAdminPassword string
@description('Public IP allowed to connect, e.g. the admin machine running add-app-db.sh')
param adminClientIp string
@minValue(7)
@maxValue(35)
param backupRetentionDays int = 14

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  sku: { name: skuName, tier: 'Burstable' }
  properties: {
    version: '18'
    administratorLogin: pgAdminUser
    administratorLoginPassword: pgAdminPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: tenant().tenantId
    }
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: backupRetentionDays, geoRedundantBackup: 'Enabled' }
    network: { publicNetworkAccess: 'Enabled' }
  }
}

resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-08-01' = {
  parent: pg
  name: adminGroupObjectId
  properties: { principalName: adminGroupName, principalType: 'Group', tenantId: tenant().tenantId }
  // Run after the firewall rules, not in parallel: while one is being written the server is busy,
  // and the Entra admin operation fails ("AadAuthOperationCannotBePerformedWhenServerIsNotAccessible").
  dependsOn: [allowAzure, allowAdmin]
}

// Allows all Azure services, not just ours. Fine for a test; for production add a
// private endpoint and drop this rule.
resource allowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: pg
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource allowAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: pg
  name: 'admin-client'
  properties: { startIpAddress: adminClientIp, endIpAddress: adminClientIp }
}

// Monthly cost alert (EUR) to the Owners, see shared/budget.bicep.
module budget '../budget.bicep' = {
  name: 'budget'
  params: { name: 'budget-${resourceGroup().name}', amount: 19, timeGrain: 'Monthly' }
}

output host string = pg.properties.fullyQualifiedDomainName
