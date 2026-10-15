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

// Allows the self-hosted GitHub Actions runner (your workstation) to reach the
// storage account's data-plane API directly for the e2e regression tests'
// blob upload/download checks. Update this if your workstation's public IP
// changes (e.g. ISP reassignment, new network/VPN) - e2e tests will fail with
// an authorization/firewall error if it goes stale.
param allowedIpAddresses = [
  '83.106.157.84/32'
]
