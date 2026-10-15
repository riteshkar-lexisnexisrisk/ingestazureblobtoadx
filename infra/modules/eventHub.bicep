@description('Event Hub namespace name.')
param namespaceName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the event hub that receives blob-created/deleted events.')
param eventHubName string = 'clf-evh-capture-blob-events'

@description('Consumer group used by Azure Data Explorer to read the event hub.')
param adxConsumerGroupName string = 'itpadxevhcaptureblobeventsconsumer'

@description('SKU name/tier for the namespace.')
param skuName string = 'Standard'

@description('SKU capacity (throughput units).')
param skuCapacity int = 1

@description('Message retention in days for the event hub.')
param messageRetentionInDays int = 7

@description('Number of partitions for the event hub.')
param partitionCount int = 1

@description('Tags applied to the resources.')
param tags object = {}

resource namespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuName
    capacity: skuCapacity
  }
  properties: {
    disableLocalAuth: true
    isAutoInflateEnabled: false
    kafkaEnabled: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    zoneRedundant: true
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: namespace
  name: eventHubName
  properties: {
    messageRetentionInDays: messageRetentionInDays
    partitionCount: partitionCount
  }
}

resource defaultConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: eventHub
  name: '$Default'
}

resource adxConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: eventHub
  name: adxConsumerGroupName
}

output namespaceId string = namespace.id
output namespaceName string = namespace.name
output eventHubId string = eventHub.id
output eventHubName string = eventHub.name
output adxConsumerGroupName string = adxConsumerGroup.name
