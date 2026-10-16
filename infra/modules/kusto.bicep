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
param mappingRuleName string = 'clf_events_capture_blobs_avro_mapping'

@description('Target table name for ingested events.')
param tableName string = 'clf_events_capture_blobs_avro'

@description('Name of the database script resource that creates/updates the capture ingestion tables, mapping, transform function, and policies.')
param captureIngestionScriptName string = 'clf-events-capture-ingestion-tables'

@description('Forces the capture ingestion KQL script to reapply on every deployment. Defaults to the deployment timestamp: the script\'s commands (.create-merge/.create-or-alter) are idempotent, so always reapplying is safe and self-heals any out-of-band manual changes to the schema.')
param captureIngestionScriptForceUpdateTag string = utcNow()

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

// Creates/updates the raw Avro ingestion table + mapping, the JSON transform
// function, the derived table + its update policy, and the ingestion
// batching policy, from adx/scripts/clf-events_capture_ingestion_tables.kql.
// All of the script's commands (.create-merge table, .create-or-alter
// function/mapping/policy) are idempotent, so safe to reapply on every
// deployment - this also self-heals any manual, out-of-band changes to the
// schema back to what's defined in source control.
resource captureIngestionScript 'Microsoft.Kusto/clusters/databases/scripts@2024-04-13' = {
  parent: eventCaptureDb
  name: captureIngestionScriptName
  properties: {
    // scriptContent is marked a secure/write-only property by the resource
    // provider itself (so its value is never echoed in deployment history or
    // what-if output), not a secret we're managing - loading it directly via
    // loadTextContent() at compile time matches Microsoft's own official
    // sample for this resource type.
    #disable-next-line use-secure-value-for-secure-inputs
    scriptContent: loadTextContent('../../adx/scripts/clf-events_capture_ingestion_tables.kql')
    continueOnErrors: false
    forceUpdateTag: captureIngestionScriptForceUpdateTag
    // RetainPermissionOnScriptCompletion (not Remove): Remove strips the
    // *entire* Admin role assignment for the deploying principal after the
    // script finishes, not just the temporary elevation this script run
    // needed - confirmed empirically, this also removed a pre-existing,
    // standing Database Admin grant the deploying principal already had,
    // locking them out of both future pipeline deployments (which need
    // write access to redeploy this very script) and interactive Data
    // Explorer access in the portal.
    principalPermissionsAction: 'RetainPermissionOnScriptCompletion'
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
  dependsOn: [
    captureIngestionScript
  ]
}

output clusterId string = cluster.id
output clusterName string = cluster.name
output clusterUri string = cluster.properties.uri
output eventCaptureDatabaseName string = eventCaptureDb.name
output eventsDatabaseName string = eventsDb.name
