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
param appIdentityName string
param pgHost string
param azureApiBase string
@description('Git commit being deployed; stored as a tag so a failed deploy can roll back to it.')
param deployedCommit string = 'unknown'

var config = loadTextContent('config.yaml')

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: appIdentityName
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
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${appIdentity.id}': {} } }
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
        { name: 'master-key', keyVaultUrl: '${keyVaultUri}secrets/litellm-master-key', identity: appIdentity.id }
        { name: 'salt-key', keyVaultUrl: '${keyVaultUri}secrets/litellm-salt-key', identity: appIdentity.id }
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
            // No AZURE_API_KEY: LiteLLM calls Azure AI with Entra tokens of id-litellm
            // (enable_azure_ad_token_refresh in config.yaml, AZURE_CREDENTIAL/AZURE_CLIENT_ID below).
            // Encrypts credentials LiteLLM stores in its database. Without it LiteLLM uses the
            // master key, so rotating the master key would make them unreadable.
            { name: 'LITELLM_SALT_KEY', secretRef: 'salt-key' }
            { name: 'AZURE_API_BASE', value: azureApiBase }
            // Same endpoint for models served through LiteLLM's azure_ai provider (see config.yaml).
            { name: 'AZURE_AI_API_BASE', value: '${endsWith(azureApiBase, '/') ? take(azureApiBase, length(azureApiBase) - 1) : azureApiBase}/openai/v1' }
            // Postgres login via the managed identity: LiteLLM fetches an Entra token as the
            // password and renews it before it expires.
            { name: 'AZURE_POSTGRESQL_AUTH', value: 'true' }
            { name: 'AZURE_CREDENTIAL', value: 'ManagedIdentityCredential' }
            { name: 'AZURE_CLIENT_ID', value: appIdentity.properties.clientId }
            { name: 'DATABASE_HOST', value: pgHost }
            { name: 'DATABASE_USER', value: appIdentity.name }
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
            // Traffic only flows once Startup and then Readiness succeed, so on a cold start every
            // probe interval adds waiting time. Startup: check every second, up to 4 minutes
            // (boot plus first-run DB migrations). Readiness: retry quickly if the first check
            // fails while the database connection is still being set up.
            { type: 'Startup', httpGet: { path: '/health/liveliness', port: 4000 }, periodSeconds: 1, failureThreshold: 240 }
            { type: 'Liveness', httpGet: { path: '/health/liveliness', port: 4000 }, periodSeconds: 30 }
            { type: 'Readiness', httpGet: { path: '/health/readiness', port: 4000 }, periodSeconds: 5 }
          ]
        }
      ]
      // At most one replica: budget/rate-limit state is cached per instance.
      // Scaling out requires Redis (router_settings.redis_*) first.
      // Scales to zero when idle (no compute cost); the first request after that waits for a cold start.
      scale: { minReplicas: 0, maxReplicas: 1 }
      volumes: [
        // Mount only the config, not the other secrets.
        { name: 'config', storageType: 'Secret', secrets: [{ secretRef: 'litellm-config', path: 'litellm-config' }] }
      ]
    }
  }
}

output url string = 'https://${app.properties.configuration.ingress.fqdn}'
