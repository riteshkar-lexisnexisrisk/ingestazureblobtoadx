using '../main.bicep'

param environmentName = 'test'
param location = 'eastus'

// Distinct, globally-unique names so Test runs alongside SharedDev.
param storageAccountName = 'stitpeventcapturetst'
param adxManagedIdentityName = 'miitpadxtest'
param eventGridManagedIdentityName = 'miitpegtest'
param eventGridNamespaceName = 'egitptest'
param systemTopicName = 'clfevhcaptureeventtopictest'
param eventHubNamespaceName = 'itpevhtest'
param kustoClusterName = 'itpadxtest'
param kustoSkuName = 'Standard_E2ads_v5'
param kustoSkuCapacity = 2
