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

// Allows the self-hosted GitHub Actions runner (your workstation) to reach the
// storage account's data-plane API directly for the e2e regression tests'
// blob upload/download checks. Update this if your workstation's public IP
// changes (e.g. ISP reassignment, new network/VPN) - e2e tests will fail with
// an authorization/firewall error if it goes stale.
param allowedIpAddresses = [
  '83.106.157.84/32'
]
