using '../main.bicep'

param environmentName = 'shareddev'
param location = 'eastus'

// Matches the existing, previously portal-created resources so the first
// pipeline run imports them in place instead of creating duplicates.
param storageAccountName = 'stitpeventcapture'
param adxManagedIdentityName = 'miitpadxdev'
param eventGridManagedIdentityName = 'miitpegdev'
param eventGridNamespaceName = 'egitpdev'
param systemTopicName = 'clfevhcaptureeventtopic'
param eventHubNamespaceName = 'itpevhdev'
param kustoClusterName = 'itpadxdev'
param kustoSkuName = 'Standard_E2ads_v5'
param kustoSkuCapacity = 2
