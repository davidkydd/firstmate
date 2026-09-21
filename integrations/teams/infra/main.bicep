targetScope = 'resourceGroup'

@description('Short lowercase deployment stem, such as fmteamsprod.')
@minLength(3)
@maxLength(18)
param namePrefix string

@description('Azure region approved for the service and its retained Teams data.')
param location string = resourceGroup().location

@description('Existing single-tenant application ID approved for the bot.')
param botAppId string

@description('Teams Bot Framework recipient ID expected in inbound activities, recorded from the approved registration.')
param botRecipientId string

@description('Approved Microsoft Entra tenant ID.')
param tenantId string

@description('Object ID of the principal used by the Mac connector.')
param macConnectorPrincipalId string

@allowed([
  'User'
  'ServicePrincipal'
])
param macConnectorPrincipalType string = 'User'

@description('Comma-separated allowlist of Entra object IDs allowed to send commands.')
param allowedSenderObjectIds string

@description('Comma-separated allowlist of Teams conversation IDs allowed to send commands and receive replies.')
param allowedConversationIds string

@description('Name of the approved existing Azure Container Registry in this resource group.')
param containerRegistryName string

@description('Repository path within the approved Azure Container Registry.')
@minLength(1)
@maxLength(255)
param containerImageRepository string = 'firstmate-teams'

@description('Exactly 64 hexadecimal characters from the approved OCI image SHA-256 digest.')
@minLength(64)
@maxLength(64)
param containerImageDigest string

@description('Name of the Key Vault certificate secret containing a PEM private key and certificate chain.')
param certificateName string

@description('Deploy the externally reachable cloud bot and Azure Bot resource only after rollout approval, app registration, certificate issuance, and image publication.')
param enableCloudService bool = false

@description('Maximum authentication attempts admitted per minute before JWT verification.')
@minValue(10)
@maxValue(600)
param authRateLimitPerMinute int = 120

@description('Retention in days for active and dead-letter queue messages.')
@minValue(1)
@maxValue(14)
param messageRetentionDays int = 7

@description('Maximum result-publication window in days before reserving the queue lifetime and a one-day delivery margin before cloud correlation expiry.')
@minValue(1)
@maxValue(350)
param resultPublicationDays int = 22

@description('Retention in days for diagnostic logs. Teams request bodies are not emitted to these logs.')
@minValue(30)
@maxValue(730)
param diagnosticRetentionDays int = 90

@description('Approved Azure Monitor action group resource ID. Leave empty to omit alert delivery until ownership is assigned.')
param alertActionGroupId string = ''

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id, namePrefix)
var serviceBusName = take('${namePrefix}-sb-${suffix}', 50)
var storageName = 'st${suffix}'
var keyVaultName = take('${namePrefix}-kv-${suffix}', 24)
var identityName = take('${namePrefix}-bot-id', 128)
var environmentName = take('${namePrefix}-env', 32)
var appName = take('${namePrefix}-bot', 32)
var botName = take('${namePrefix}-azure-bot', 42)
var requestQueueName = 'teams-requests-v1'
var resultQueueName = 'teams-results-v1'
var tableName = 'teamsrequests'
var senderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39')
var receiverRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')
var tableContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var acrRepositoryReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b93aa761-3e63-49ed-ac28-beffa264f7ac')
var correlationRetentionDays = resultPublicationDays + messageRetentionDays + 1
var containerImage = '${containerRegistry.properties.loginServer}/${containerImageRepository}@sha256:${containerImageDigest}'
var conditionRepository = replace(containerImageRepository, '\'', '')
var containerRepositoryReadCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${conditionRepository}\'))'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource botIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: serviceBusName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
  }
}

resource requestQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: requestQueueName
  properties: {
    lockDuration: 'PT5M'
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P${messageRetentionDays}D'
    deadLetteringOnMessageExpiration: true
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'P7D'
    enablePartitioning: false
  }
}

resource resultQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: resultQueueName
  properties: {
    lockDuration: 'PT5M'
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P${messageRetentionDays}D'
    deadLetteringOnMessageExpiration: true
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'P7D'
    enablePartitioning: false
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource requestTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: tableName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: take('${namePrefix}-logs-${suffix}', 63)
  location: location
  properties: {
    retentionInDays: diagnosticRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: take('${namePrefix}-insights-${suffix}', 255)
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource containerEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
  }
}

resource cloudRequestSend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(requestQueue.id, botIdentity.id, senderRoleId)
  scope: requestQueue
  properties: {
    principalId: botIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: senderRoleId
  }
}

resource cloudResultReceive 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resultQueue.id, botIdentity.id, receiverRoleId)
  scope: resultQueue
  properties: {
    principalId: botIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: receiverRoleId
  }
}

resource macRequestReceive 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(requestQueue.id, macConnectorPrincipalId, receiverRoleId)
  scope: requestQueue
  properties: {
    principalId: macConnectorPrincipalId
    principalType: macConnectorPrincipalType
    roleDefinitionId: receiverRoleId
  }
}

resource macResultSend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resultQueue.id, macConnectorPrincipalId, senderRoleId)
  scope: resultQueue
  properties: {
    principalId: macConnectorPrincipalId
    principalType: macConnectorPrincipalType
    roleDefinitionId: senderRoleId
  }
}

resource cloudTableAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, botIdentity.id, tableContributorRoleId)
  scope: storage
  properties: {
    principalId: botIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tableContributorRoleId
  }
}

resource cloudCertificateAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, botIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: botIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource cloudRegistryPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableCloudService) {
  name: guid(containerRegistry.id, botIdentity.id, acrRepositoryReaderRoleId, containerImageRepository)
  scope: containerRegistry
  properties: {
    principalId: botIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrRepositoryReaderRoleId
    condition: containerRepositoryReadCondition
    conditionVersion: '2.0'
    description: 'Pull Firstmate Teams images only from the configured repository.'
  }
}

resource cloudApp 'Microsoft.App/containerApps@2024-03-01' = if (enableCloudService) {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${botIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: botIdentity.id
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'teams-bot'
          image: containerImage
          env: [
            { name: 'FM_TEAMS_ENABLED', value: '1' }
            { name: 'FM_TEAMS_TENANT_ID', value: tenantId }
            { name: 'FM_TEAMS_BOT_APP_ID', value: botAppId }
            { name: 'FM_TEAMS_BOT_RECIPIENT_ID', value: botRecipientId }
            { name: 'FM_TEAMS_ALLOWED_SENDER_IDS', value: allowedSenderObjectIds }
            { name: 'FM_TEAMS_ALLOWED_CONVERSATION_IDS', value: allowedConversationIds }
            { name: 'FM_TEAMS_SERVICE_BUS_NAMESPACE', value: serviceBus.name }
            { name: 'FM_TEAMS_REQUEST_QUEUE', value: requestQueue.name }
            { name: 'FM_TEAMS_RESULT_QUEUE', value: resultQueue.name }
            { name: 'FM_TEAMS_TABLE_ENDPOINT', value: 'https://${storage.name}.table.${environment().suffixes.storage}' }
            { name: 'FM_TEAMS_TABLE_NAME', value: requestTable.name }
            { name: 'FM_TEAMS_KEY_VAULT_URL', value: keyVault.properties.vaultUri }
            { name: 'FM_TEAMS_CERTIFICATE_NAME', value: certificateName }
            { name: 'FM_TEAMS_MANAGED_IDENTITY_CLIENT_ID', value: botIdentity.properties.clientId }
            { name: 'FM_TEAMS_AUTH_RATE_LIMIT_PER_MINUTE', value: string(authRateLimitPerMinute) }
            { name: 'FM_TEAMS_RETENTION_DAYS', value: string(correlationRetentionDays) }
            { name: 'FM_TEAMS_MESSAGE_RETENTION_DAYS', value: string(messageRetentionDays) }
            { name: 'OutboundHostValidator__Enabled', value: 'true' }
            { name: 'OutboundHostValidator__IncludeDefaultMicrosoftHosts', value: 'true' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 15
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    cloudRequestSend
    cloudResultReceive
    cloudTableAccess
    cloudCertificateAccess
    cloudRegistryPull
  ]
}

resource azureBot 'Microsoft.BotService/botServices@2022-09-15' = if (enableCloudService) {
  name: botName
  location: 'global'
  kind: 'azurebot'
  sku: {
    name: 'S1'
  }
  properties: {
    displayName: 'Firstmate'
    endpoint: 'https://${cloudApp!.properties.configuration.ingress.fqdn}/api/messages'
    msaAppId: botAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
    isCmekEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource teamsChannel 'Microsoft.BotService/botServices/channels@2022-09-15' = if (enableCloudService) {
  parent: azureBot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      isEnabled: true
    }
  }
}

resource deadLetterAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(alertActionGroupId)) {
  name: '${namePrefix}-dead-letter'
  location: 'global'
  properties: {
    description: 'Firstmate Teams messages reached a dead-letter queue.'
    severity: 1
    enabled: true
    scopes: [serviceBus.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'DeadLetteredMessages'
          metricName: 'DeadletteredMessages'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
        }
      ]
    }
    actions: [
      {
        actionGroupId: alertActionGroupId
      }
    ]
  }
}

resource serviceBusDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'firstmate-teams'
  scope: serviceBus
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output serviceBusNamespace string = serviceBus.name
output requestQueue string = requestQueue.name
output resultQueue string = resultQueue.name
output tableEndpoint string = 'https://${storage.name}.table.${environment().suffixes.storage}'
output tableName string = requestTable.name
output keyVaultUrl string = keyVault.properties.vaultUri
output managedIdentityClientId string = botIdentity.properties.clientId
output botEndpoint string = enableCloudService ? 'https://${cloudApp!.properties.configuration.ingress.fqdn}/api/messages' : 'disabled'
