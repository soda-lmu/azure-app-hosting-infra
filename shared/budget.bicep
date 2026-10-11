// Cost budget for the resource group this module is deployed to. Budgets only send
// alerts, they don't stop spending. Alerts go to the Owners, by role, so no email address is in
// git: Owners of the resource group (contactRoles) and, because a budget at resource group scope
// requires an email address or an action group, Owners of the subscription via an action group.
param name string
@description('Whole units of the billing currency (EUR): Azure accepts integers only.')
@minValue(1)
param amount int
@description('Period the amount applies to; the cost is reset at the start of each period.')
@allowed(['Monthly', 'Quarterly', 'Annually'])
param timeGrain string
@description('First day of the current month: Azure only accepts a past start within the current period (valid for every timeGrain).')
param startDate string = '${utcNow('yyyy-MM')}-01'

var ownerRole = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

resource owners 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${name}'
  location: 'global'
  properties: {
    groupShortName: 'owners'
    enabled: true
    armRoleReceivers: [{ name: 'owners', roleId: ownerRole, useCommonAlertSchema: true }]
  }
}

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: timeGrain
    timePeriod: { startDate: startDate }
    notifications: {
      // One alert, once the actual cost exceeds the budget.
      actual100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: []
        contactRoles: ['Owner']
        contactGroups: [owners.id]
      }
    }
  }
}
