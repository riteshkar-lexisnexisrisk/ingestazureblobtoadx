@description('Globally unique storage account name (lowercase, 3-24 chars).')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region for the storage account.')
param location string = resourceGroup().location

@description('Blob container used to land captured events.')
param containerName string = 'clf'

@description('Public IPv4 addresses or CIDR ranges allowed through the storage firewall (e.g. the self-hosted runner workstation public IP), in addition to trusted Azure services. Update this if the workstation public IP changes.')
param allowedIpAddresses array = []

@description('Tags applied to the resource.')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: [
        for ip in allowedIpAddresses: {
          value: ip
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
output containerName string = container.name
