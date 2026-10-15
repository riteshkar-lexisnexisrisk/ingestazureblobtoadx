targetScope = 'resourceGroup'

@description('Short environment name used in tags (e.g. shareddev, test).')
param environmentName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Globally unique storage account name for captured blobs.')
param storageAccountName string

@description('Name of the user-assigned managed identity used by Azure Data Explorer.')
param adxManagedIdentityName string

@description('Name of the user-assigned managed identity used by Event Grid.')
param eventGridManagedIdentityName string

@description('Event Grid namespace name.')
param eventGridNamespaceName string

@description('Event Grid system topic name that watches the storage account.')
param systemTopicName string

@description('Event Hub namespace name.')
param eventHubNamespaceName string

@description('Azure Data Explorer (Kusto) cluster name.')
param kustoClusterName string

@description('Kusto cluster SKU name. Use a smaller SKU for non-production environments.')
param kustoSkuName string = 'Standard_E2ads_v5'

@description('Kusto cluster SKU capacity (instance count).')
param kustoSkuCapacity int = 2

@description('Public IPv4 addresses or CIDR ranges allowed through the storage account firewall, in addition to trusted Azure services (e.g. the self-hosted runner workstation public IP).')
param allowedIpAddresses array = []

@description('Optional GUIDs of role assignments that were already created manually (e.g. via the portal) before this environment was adopted into Bicep, keyed by a fixed role key. Leave a value empty (the default) to let Bicep compute a fresh, deterministic GUID instead - safe for any new environment/subscription, since nothing pre-exists there to conflict with. Only set these for an environment where the exact role assignment GUIDs are already known (looked up via "az role assignment list") to avoid a RoleAssignmentExists conflict.')
param existingRoleAssignmentIds object = {
  adxStorageBlobDataReader: ''
  adxEventHubDataReceiver: ''
  eventGridEventHubDataSender: ''
}

@description('Common tags applied to every resource.')
param tags object = {
  environment: environmentName
  workload: 'ingestazureblobtoadx'
  managedBy: 'bicep'
}

// Built-in role definition IDs. These are global constants published by
// Microsoft (the same GUID for every tenant/subscription), unlike role
// *assignment* names, which are unique per grant. The pipeline resolves the
// current value dynamically by role name (via "az role definition list
// --name") before every deployment, so this template never needs to be
// hand-edited if Microsoft were to change one. The defaults below are the
// current, documented values, used as a fallback only for direct/local
// deployments that bypass the pipeline's resolution step.
@description('Role definition ID for the built-in "Storage Blob Data Reader" role.')
param storageBlobDataReaderRoleId string = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

@description('Role definition ID for the built-in "Azure Event Hubs Data Receiver" role.')
param eventHubsDataReceiverRoleId string = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'

@description('Role definition ID for the built-in "Azure Event Hubs Data Sender" role.')
param eventHubsDataSenderRoleId string = '2b629674-e913-4c01-ae53-ef4638d8f975'

module adxIdentity 'modules/managedIdentity.bicep' = {
  name: 'adxIdentity'
  params: {
    name: adxManagedIdentityName
    location: location
    tags: tags
  }
}

module eventGridIdentity 'modules/managedIdentity.bicep' = {
  name: 'eventGridIdentity'
  params: {
    name: eventGridManagedIdentityName
    location: location
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    allowedIpAddresses: allowedIpAddresses
  }
}

module eventHub 'modules/eventHub.bicep' = {
  name: 'eventHub'
  params: {
    namespaceName: eventHubNamespaceName
    location: location
    tags: tags
  }
}

module eventGrid 'modules/eventGrid.bicep' = {
  name: 'eventGrid'
  params: {
    namespaceName: eventGridNamespaceName
    systemTopicName: systemTopicName
    location: location
    storageAccountId: storage.outputs.id
    managedIdentityId: eventGridIdentity.outputs.id
    eventHubResourceId: eventHub.outputs.eventHubId
    tags: tags
  }
}

module kusto 'modules/kusto.bicep' = {
  name: 'kusto'
  params: {
    clusterName: kustoClusterName
    location: location
    skuName: kustoSkuName
    skuCapacity: kustoSkuCapacity
    managedIdentityId: adxIdentity.outputs.id
    eventSubscriptionId: '${storage.outputs.id}/providers/Microsoft.EventGrid/eventSubscriptions/${eventGrid.outputs.eventSubscriptionName}'
    eventHubResourceId: eventHub.outputs.eventHubId
    consumerGroupName: eventHub.outputs.adxConsumerGroupName
    storageAccountId: storage.outputs.id
    tags: tags
  }
}

// --- RBAC: least-privilege access for the ingestion pipeline ---

resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
  dependsOn: [
    storage
  ]
}

resource eventHubNamespaceExisting 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
  dependsOn: [
    eventHub
  ]
}

// These three role assignments may already exist from before the environment
// was adopted into Bicep (e.g. created manually via the portal). Azure RBAC
// rejects a second role assignment for the same (principal, role, scope)
// tuple even under a different resource name, so if a known existing GUID is
// supplied via existingRoleAssignmentIds, it's reused here; otherwise a fresh
// deterministic GUID is computed, which is safe for any new
// environment/subscription since nothing pre-exists there to conflict with.
resource adxStorageBlobDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: empty(existingRoleAssignmentIds.adxStorageBlobDataReader)
    ? guid(resourceGroup().id, storageAccountName, adxManagedIdentityName, storageBlobDataReaderRoleId)
    : existingRoleAssignmentIds.adxStorageBlobDataReader
  scope: storageAccountExisting
  properties: {
    principalId: adxIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
  }
}

resource adxEventHubDataReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: empty(existingRoleAssignmentIds.adxEventHubDataReceiver)
    ? guid(resourceGroup().id, eventHubNamespaceName, adxManagedIdentityName, eventHubsDataReceiverRoleId)
    : existingRoleAssignmentIds.adxEventHubDataReceiver
  scope: eventHubNamespaceExisting
  properties: {
    principalId: adxIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
  }
}

resource eventGridEventHubDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: empty(existingRoleAssignmentIds.eventGridEventHubDataSender)
    ? guid(resourceGroup().id, eventHubNamespaceName, eventGridManagedIdentityName, eventHubsDataSenderRoleId)
    : existingRoleAssignmentIds.eventGridEventHubDataSender
  scope: eventHubNamespaceExisting
  properties: {
    principalId: eventGridIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataSenderRoleId)
  }
}

output storageAccountName string = storage.outputs.name
output eventHubNamespaceName string = eventHub.outputs.namespaceName
output eventGridSystemTopicName string = systemTopicName
output kustoClusterName string = kusto.outputs.clusterName
output kustoClusterUri string = kusto.outputs.clusterUri
output eventCaptureDatabaseName string = kusto.outputs.eventCaptureDatabaseName
output eventsDatabaseName string = kusto.outputs.eventsDatabaseName
