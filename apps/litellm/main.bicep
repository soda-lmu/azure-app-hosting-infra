// LiteLLM proxy: Container Apps environment and the container app. This is the routine part
// (what CI deploys). Identity and Key Vault come from setup.bicep in the secrets resource group;
// this template only references them and never sees a secret value.
// The LiteLLM config (models, endpoints, prices) lives in config.yaml next to this file.
import { names, keyVaultName } from 'names.bicep'

param location string = resourceGroup().location
param pgHost string
param azureApiBase string
@description('Git commit being deployed; stored as a tag so a failed deploy can roll back to it.')
param deployedCommit string = 'unknown'
// Azure only issues a managed certificate for a hostname already on the app, so the custom
// domain is set up in stages (deploy.sh runs them; CI deploys the stage domain-stage.sh picks):
@description('''Custom domain (names.customDomain) setup stage:
none: no custom domain.
hostname: add the hostname to the app without a certificate, then create the managed certificate for it.
bound: serve the domain with that certificate (it must exist). Routine deploys.''')
@allowed(['none', 'hostname', 'bound'])
param customDomainStage string = 'bound'

var config = loadTextContent('config.yaml')
var domainStage = empty(names.customDomain) ? 'none' : customDomainStage
var domainBound = domainStage == 'bound'

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: names.appIdentity
  scope: resourceGroup(names.secretsResourceGroup)
}

// Computed rather than read from the vault, so the deploying identity (CI) needs no rights on it.
var keyVaultUri = 'https://${keyVaultName(subscription().subscriptionId, names.secretsResourceGroup)}${environment().suffixes.keyvaultDns}/'

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.logWorkspace
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource env 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: names.containerAppEnvironment
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
  name: names.containerApp
  location: location
  tags: { commit: deployedCommit }
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${appIdentity.id}': {} } }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 4000
        transport: 'auto'
        // Must be listed on every deploy: a deploy without it removes the domain from the app.
        // Referenced by id, not as a resource: in stage 'hostname' the certificate comes after the app.
        customDomains: {
          none: []
          hostname: [{ name: names.customDomain, bindingType: 'Disabled' }]
          bound: [
            {
              name: names.customDomain
              bindingType: 'SniEnabled'
              certificateId: resourceId('Microsoft.App/managedEnvironments/managedCertificates', env.name, names.customDomainCertificate)
            }
          ]
        }[domainStage]
      }
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
          // Tag and digest: a re-pushed tag can't change what runs. Renovate updates both.
          image: 'ghcr.io/berriai/litellm-database:v1.105.0@sha256:f99e4cc55ce8a1c6888504ac6eff147868979d37363a7246cf804bbabdc27e88'
          args: ['--config', '/mnt/secrets/litellm-config', '--port', '4000']
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: [
            { name: 'LITELLM_MASTER_KEY', secretRef: 'master-key' }
            // No AZURE_API_KEY: LiteLLM calls Azure AI with Entra tokens of the app identity
            // (enable_azure_ad_token_refresh in config.yaml, AZURE_CREDENTIAL/AZURE_CLIENT_ID below).
            // LITELLM_SALT_KEY encrypts credentials LiteLLM stores in its database.
            { name: 'LITELLM_SALT_KEY', secretRef: 'salt-key' }
            { name: 'AZURE_API_BASE', value: azureApiBase }
            // Same endpoint for models served through LiteLLM's azure_ai provider (see config.yaml).
            { name: 'AZURE_AI_API_BASE', value: uri(azureApiBase, 'openai/v1') }
            // Postgres login via the managed identity: LiteLLM fetches an Entra token as the
            // password and renews it before it expires.
            { name: 'AZURE_POSTGRESQL_AUTH', value: 'true' }
            { name: 'AZURE_CREDENTIAL', value: 'ManagedIdentityCredential' }
            { name: 'AZURE_CLIENT_ID', value: appIdentity.properties.clientId }
            { name: 'DATABASE_HOST', value: pgHost }
            { name: 'DATABASE_USER', value: appIdentity.name }
            { name: 'DATABASE_NAME', value: names.database }
            { name: 'DATABASE_SSLMODE', value: 'verify-full' }
            // Links in the admin UI (and SSO redirects) point here.
            ...(domainBound ? [{ name: 'PROXY_BASE_URL', value: 'https://${names.customDomain}' }] : [])
            // Secret changes alone don't start a new revision. This hash changes with the
            // config, so a new revision rolls out exactly when config.yaml changes.
            { name: 'CONFIG_HASH', value: uniqueString(config) }
          ]
          // LiteLLM expects config.yaml as a file, passing it as a secret is a useful detour. 
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

// Free TLS certificate for the custom domain, renewed by Azure. Validated through the CNAME record;
// created once (stage 'hostname'), later deploys leave it alone.
resource certificate 'Microsoft.App/managedEnvironments/managedCertificates@2025-01-01' = if (domainStage == 'hostname') {
  parent: env
  name: names.customDomainCertificate
  location: location
  properties: { subjectName: names.customDomain, domainControlValidation: 'CNAME' }
  dependsOn: [app]
}

output url string = 'https://${domainBound ? names.customDomain : app.properties.configuration.ingress.fqdn}'
// For the DNS records of the custom domain (deploy.sh).
output fqdn string = app.properties.configuration.ingress.fqdn
output domainVerificationId string = app.properties.customDomainVerificationId
