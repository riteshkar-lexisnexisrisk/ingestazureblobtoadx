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

@description('Common tags applied to every resource.')
param tags object = {
  environment: environmentName
  workload: 'ingestazureblobtoadx'
  managedBy: 'bicep'
}

// Built-in role definition IDs (stable across tenants).
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
var eventHubsDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'

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

// These three role assignments were originally created manually (portal) when
// the resource group was first set up, so they already exist with specific
// GUID names. Azure RBAC rejects a second role assignment for the same
// (principal, role, scope) tuple even under a different resource name, so the
// `name:` below must match the existing assignment's GUID exactly - using a
// freshly computed guid() here would fail with "RoleAssignmentExists".
resource adxStorageBlobDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'eb33d15f-eac7-4e9b-bb0d-fe81de2ce39e'
  scope: storageAccountExisting
  properties: {
    principalId: adxIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
  }
}

resource adxEventHubDataReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'ce6bb43e-8354-4d5d-bc3d-750c36c77cce'
  scope: eventHubNamespaceExisting
  properties: {
    principalId: adxIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
  }
}

resource eventGridEventHubDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: '0a2d326f-5f91-47ff-bfd0-0b0574403d61'
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
