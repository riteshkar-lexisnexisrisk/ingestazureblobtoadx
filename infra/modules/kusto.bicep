@description('Azure Data Explorer (Kusto) cluster name.')
param clusterName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Cluster SKU name.')
param skuName string = 'Standard_E2ads_v5'

@description('Cluster SKU tier.')
param skuTier string = 'Standard'

@description('Cluster instance capacity.')
param skuCapacity int = 2

@description('Availability zones for the cluster.')
param zones array = [
  '1'
  '2'
  '3'
]

@description('Resource ID of the user-assigned managed identity used by the cluster for data connections.')
param managedIdentityId string

@description('Name of the database that receives blob-captured events.')
param eventCaptureDatabaseName string = 'clf-event-capture'

@description('Name of the secondary events database.')
param eventsDatabaseName string = 'clf-events'

@description('Hot cache retention window (ISO 8601 duration).')
param hotCachePeriod string = 'P7D'

@description('Soft delete retention window (ISO 8601 duration).')
param softDeletePeriod string = 'P7D'

@description('Data connection name linking Event Grid/Event Hub to the event-capture database.')
param dataConnectionName string = 'itp-evg-adx-connection'

@description('Resource ID of the Event Grid event subscription that raises blob events.')
param eventSubscriptionId string

@description('Resource ID of the event hub that delivers the events.')
param eventHubResourceId string

@description('Event hub consumer group used by the data connection.')
param consumerGroupName string

@description('Resource ID of the storage account referenced by the managed-identity data connection.')
param storageAccountId string

@description('Name of the ingestion mapping rule applied to incoming events.')
param mappingRuleName string = 'evh-capture-blobs_mapping'

@description('Target table name for ingested events.')
param tableName string = 'evh-capture-blobs'

@description('Tags applied to the resources.')
param tags object = {}

resource cluster 'Microsoft.Kusto/clusters@2024-04-13' = {
  name: clusterName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
    capacity: skuCapacity
  }
  zones: zones
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    enableAutoStop: true
    enableDiskEncryption: true
    enableDoubleEncryption: false
    enablePurge: true
    enableStreamingIngest: true
    engineType: 'V3'
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: 'Disabled'
  }
}

resource eventCaptureDb 'Microsoft.Kusto/clusters/databases@2024-04-13' = {
  parent: cluster
  name: eventCaptureDatabaseName
  kind: 'ReadWrite'
  location: location
  properties: {
    hotCachePeriod: hotCachePeriod
    softDeletePeriod: softDeletePeriod
  }
}

resource eventsDb 'Microsoft.Kusto/clusters/databases@2024-04-13' = {
  parent: cluster
  name: eventsDatabaseName
  kind: 'ReadWrite'
  location: location
  properties: {
    hotCachePeriod: hotCachePeriod
    softDeletePeriod: softDeletePeriod
  }
}

resource dataConnection 'Microsoft.Kusto/clusters/databases/dataConnections@2024-04-13' = {
  parent: eventCaptureDb
  kind: 'EventGridWithManagedIdentity'
  name: dataConnectionName
  location: location
  properties: {
    blobStorageEventType: 'Microsoft.Storage.BlobCreated'
    consumerGroup: consumerGroupName
    dataFormat: 'AVRO'
    databaseRouting: 'Single'
    eventGridResourceId: eventSubscriptionId
    eventHubResourceIdForManagedIdentity: eventHubResourceId
    ignoreFirstRecord: false
    managedIdentityResourceId: managedIdentityId
    mappingRuleName: mappingRuleName
    storageAccountResourceIdForManagedIdentity: storageAccountId
    tableName: tableName
  }
}

output clusterId string = cluster.id
output clusterName string = cluster.name
output clusterUri string = cluster.properties.uri
output eventCaptureDatabaseName string = eventCaptureDb.name
output eventsDatabaseName string = eventsDb.name
