@description('Event Grid namespace name (reserved for future custom-topic/MQTT use).')
param namespaceName string

@description('System topic name watching the storage account for blob events.')
param systemTopicName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Resource ID of the storage account that is the event source.')
param storageAccountId string

@description('Resource ID of the user-assigned managed identity used by Event Grid.')
param managedIdentityId string

@description('Event subscription name that routes blob events to the event hub.')
param eventSubscriptionName string = 'clfevhcapturesubscription'

@description('Resource ID of the destination event hub.')
param eventHubResourceId string

@description('Subject prefix filter for the event subscription.')
param subjectBeginsWith string = '/blobServices/default/containers/clf/blobs/itp-eventhub-inqtracking-dev'

@description('Subject suffix filter for the event subscription.')
param subjectEndsWith string = 'Avro'

@description('Tags applied to the resources.')
param tags object = {}

resource egNamespace 'Microsoft.EventGrid/namespaces@2024-06-01-preview' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    isZoneRedundant: true
    minimumTlsVersionAllowed: '1.2'
    publicNetworkAccess: 'Enabled'
    topicsConfiguration: {}
  }
}

resource systemTopic 'Microsoft.EventGrid/systemTopics@2024-06-01-preview' = {
  name: systemTopicName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    source: storageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2024-06-01-preview' = {
  parent: systemTopic
  name: eventSubscriptionName
  properties: {
    deliveryWithResourceIdentity: {
      destination: {
        endpointType: 'EventHub'
        properties: {
          resourceId: eventHubResourceId
        }
      }
      identity: {
        type: 'UserAssigned'
        userAssignedIdentity: managedIdentityId
      }
    }
    eventDeliverySchema: 'EventGridSchema'
    filter: {
      enableAdvancedFilteringOnArrays: true
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
        'Microsoft.Storage.BlobDeleted'
      ]
      subjectBeginsWith: subjectBeginsWith
      subjectEndsWith: subjectEndsWith
    }
    retryPolicy: {
      eventTimeToLiveInMinutes: 1440
      maxDeliveryAttempts: 30
    }
  }
}

output systemTopicId string = systemTopic.id
output eventSubscriptionId string = eventSubscription.id
output eventSubscriptionName string = eventSubscription.name
