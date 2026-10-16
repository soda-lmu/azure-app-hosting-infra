// Cost budget for the resource group this module is deployed to. Budgets only send alerts, they
// don't stop spending. Alerts go to contactEmails (from config.sops.yaml: BUDGET_ALERT_EMAILS, so no address
// is in git).
param name string
@description('Whole units of the billing currency (EUR): Azure accepts integers only.')
@minValue(1)
param amount int
@description('Period the amount applies to; the cost is reset at the start of each period.')
@allowed(['Monthly', 'Quarterly', 'Annually'])
param timeGrain string
@description('Who gets the alert. A budget at resource group scope needs at least one address.')
@minLength(1)
param contactEmails string[]
@description('First day of the current month: Azure only accepts a past start within the current period (valid for every timeGrain).')
param startDate string = '${utcNow('yyyy-MM')}-01'

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
        contactEmails: contactEmails
      }
    }
  }
}
