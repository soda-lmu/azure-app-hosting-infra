// LiteLLM proxy: Container Apps environment and the container app. This is the routine part
// (what CI deploys). Identity and Key Vault come from setup.bicep in the secrets resource group;
// this template only references them and never sees a secret value.
// The LiteLLM config (models, endpoints, prices) lives in config.yaml next to this file.
import { keyVaultName } from 'names.bicep'

param location string = resourceGroup().location
param appName string
param environmentName string
#disable-next-line secure-secrets-in-params // a resource group name, not a secret
param secretsResourceGroup string
param identityName string
param pgHost string
param azureApiBase string
@description('Git commit being deployed; stored as a tag so a failed deploy can roll back to it.')
param deployedCommit string = 'unknown'

var config = loadTextContent('config.yaml')

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
  scope: resourceGroup(secretsResourceGroup)
}

// Computed rather than read from the vault, so the deploying identity (CI) needs no rights on it.
var keyVaultUri = 'https://${keyVaultName(subscription().subscriptionId, secretsResourceGroup)}${environment().suffixes.keyvaultDns}/'

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${appName}'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource env 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  tags: { commit: deployedCommit }
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identity.id}': {} } }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 4000, transport: 'auto' }
      secrets: [
        #disable-next-line use-secure-value-for-secure-inputs // config.yaml holds no secrets
        { name: 'litellm-config', value: config }
        // Versionless Key Vault references: a new secret version is picked up within
        // 30 minutes and the revision restarts automatically.
        { name: 'master-key', keyVaultUrl: '${keyVaultUri}secrets/litellm-master-key', identity: identity.id }
        { name: 'azure-api-key', keyVaultUrl: '${keyVaultUri}secrets/azure-api-key', identity: identity.id }
      ]
    }
    template: {
      containers: [
        {
          name: 'litellm'
          image: 'ghcr.io/berriai/litellm-database:v1.104.0'
          args: ['--config', '/mnt/secrets/litellm-config', '--port', '4000']
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: [
            { name: 'LITELLM_MASTER_KEY', secretRef: 'master-key' }
            { name: 'AZURE_API_KEY', secretRef: 'azure-api-key' }
            { name: 'AZURE_API_BASE', value: azureApiBase }
            // Postgres login via the managed identity: LiteLLM fetches an Entra token as the
            // password and renews it before it expires.
            { name: 'AZURE_POSTGRESQL_AUTH', value: 'true' }
            { name: 'AZURE_CREDENTIAL', value: 'ManagedIdentityCredential' }
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
            { name: 'DATABASE_HOST', value: pgHost }
            { name: 'DATABASE_USER', value: identity.name }
            { name: 'DATABASE_NAME', value: 'litellm' }
            // Verify certificate chain (system CA bundle) and host name: the Entra token travels
            // in the password field, so it must only ever reach the real server.
            { name: 'DATABASE_SSLMODE', value: 'verify-full' }
            // Secret changes alone don't start a new revision. This hash changes with the
            // config, so a new revision rolls out exactly when config.yaml changes.
            { name: 'CONFIG_HASH', value: uniqueString(config) }
          ]
          volumeMounts: [{ volumeName: 'config', mountPath: '/mnt/secrets' }]
          probes: [
            // Boot plus first-run DB migrations take a while.
            { type: 'Startup', httpGet: { path: '/health/liveliness', port: 4000 }, periodSeconds: 10, failureThreshold: 30 }
            { type: 'Liveness', httpGet: { path: '/health/liveliness', port: 4000 }, periodSeconds: 30 }
            { type: 'Readiness', httpGet: { path: '/health/readiness', port: 4000 }, periodSeconds: 30 }
          ]
        }
      ]
      // Exactly one replica: budget/rate-limit state is cached per instance.
      // Scaling out requires Redis (router_settings.redis_*) first.
      scale: { minReplicas: 1, maxReplicas: 1 }
      volumes: [
        // Mount only the config, not the other secrets.
        { name: 'config', storageType: 'Secret', secrets: [{ secretRef: 'litellm-config', path: 'litellm-config' }] }
      ]
    }
  }
}

output url string = 'https://${app.properties.configuration.ingress.fqdn}'
