<#
.SYNOPSIS
    End-to-end regression tests. Run AFTER a deployment, against a live resource
    group, to confirm the blob -> Event Grid -> Event Hub -> ADX ingestion
    pipeline is actually wired up and healthy (not just "the ARM deployment
    succeeded").

.PARAMETER ResourceGroup
    Resource group to validate (e.g. itp for SharedDev, itp-test for Test).

.PARAMETER ParameterFile
    The .bicepparam file for the environment under test, used to discover the
    expected resource names.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ParameterFile
)

Describe 'Ingestion pipeline is deployed and healthy' {

    BeforeAll {
        function Get-BicepParamValue {
            param([string]$Content, [string]$Name)
            if ($Content -match "param $Name\s*=\s*'([^']+)'") { return $Matches[1] }
            throw "Could not find parameter '$Name' in the parameter file"
        }

        $paramContent = Get-Content $ParameterFile -Raw
        $StorageAccountName = Get-BicepParamValue $paramContent 'storageAccountName'
        $EventHubNamespaceName = Get-BicepParamValue $paramContent 'eventHubNamespaceName'
        $KustoClusterName = Get-BicepParamValue $paramContent 'kustoClusterName'
        $AdxManagedIdentityName = Get-BicepParamValue $paramContent 'adxManagedIdentityName'
        $EventGridManagedIdentityName = Get-BicepParamValue $paramContent 'eventGridManagedIdentityName'
        $SystemTopicName = Get-BicepParamValue $paramContent 'systemTopicName'
    }

    It 'storage account exists and is provisioned' {
        $json = az storage account show -g $ResourceGroup -n $StorageAccountName -o json 2>$null | ConvertFrom-Json
        $json | Should -Not -BeNullOrEmpty
        $json.provisioningState | Should -Be 'Succeeded'
    }

    It 'storage account has the clf blob container' {
        $containers = az storage container list --account-name $StorageAccountName --auth-mode key --only-show-errors -o json 2>$null | ConvertFrom-Json
        $containers.name | Should -Contain 'clf'
    }

    It 'event hub namespace exists and is provisioned' {
        $json = az eventhubs namespace show -g $ResourceGroup -n $EventHubNamespaceName -o json 2>$null | ConvertFrom-Json
        $json | Should -Not -BeNullOrEmpty
        $json.provisioningState | Should -Be 'Succeeded'
    }

    It 'event hub clf-evh-capture-blob-events exists' {
        $json = az eventhubs eventhub show -g $ResourceGroup --namespace-name $EventHubNamespaceName -n 'clf-evh-capture-blob-events' -o json 2>$null | ConvertFrom-Json
        $json | Should -Not -BeNullOrEmpty
    }

    It 'ADX consumer group exists on the event hub' {
        $groups = az eventhubs eventhub consumer-group list -g $ResourceGroup --namespace-name $EventHubNamespaceName --eventhub-name 'clf-evh-capture-blob-events' -o json 2>$null | ConvertFrom-Json
        $groups.name | Should -Contain 'itpadxevhcaptureblobeventsconsumer'
    }

    It 'event grid system topic exists and points at the storage account' {
        $json = az eventgrid system-topic show -g $ResourceGroup -n $SystemTopicName -o json 2>$null | ConvertFrom-Json
        $json | Should -Not -BeNullOrEmpty
        $json.source | Should -Match $StorageAccountName
    }

    It 'event grid subscription targets the event hub' {
        $json = az eventgrid system-topic event-subscription show -g $ResourceGroup --system-topic-name $SystemTopicName -n 'clfevhcapturesubscription' -o json 2>$null | ConvertFrom-Json
        $json | Should -Not -BeNullOrEmpty
        $json.deliveryWithResourceIdentity.destination.endpointType | Should -Be 'EventHub'
        $json.deliveryWithResourceIdentity.destination.resourceId | Should -Match $EventHubNamespaceName
    }

    It 'Kusto cluster is running' {
        $json = az kusto cluster show -g $ResourceGroup -n $KustoClusterName --only-show-errors -o json 2>$null | ConvertFrom-Json
        $json | Should -Not -BeNullOrEmpty
        $json.state | Should -BeIn @('Running', 'Starting')
    }

    It 'both Kusto databases exist' {
        $databases = az kusto database list -g $ResourceGroup --cluster-name $KustoClusterName --only-show-errors -o json 2>$null | ConvertFrom-Json
        $databaseNames = $databases | ForEach-Object { ($_.name -split '/')[-1] }
        $databaseNames | Should -Contain 'clf-event-capture'
        $databaseNames | Should -Contain 'clf-events'
    }

    It 'Kusto data connection to the event hub exists' {
        $connections = az kusto data-connection list -g $ResourceGroup --cluster-name $KustoClusterName --database-name 'clf-event-capture' --only-show-errors -o json 2>$null | ConvertFrom-Json
        $connectionNames = $connections | ForEach-Object { ($_.name -split '/')[-1] }
        $connectionNames | Should -Contain 'itp-evg-adx-connection'
    }

    It 'the ADX managed identity can read blobs (RBAC smoke check)' {
        $identity = az identity show -g $ResourceGroup -n $AdxManagedIdentityName -o json 2>$null | ConvertFrom-Json
        $storageId = az storage account show -g $ResourceGroup -n $StorageAccountName --query id -o tsv 2>$null
        $assignments = az role assignment list --assignee $identity.principalId --scope $storageId -o json 2>$null | ConvertFrom-Json
        $assignments.roleDefinitionName | Should -Contain 'Storage Blob Data Reader'
    }

    It 'the Event Grid managed identity can send to the event hub (RBAC smoke check)' {
        $identity = az identity show -g $ResourceGroup -n $EventGridManagedIdentityName -o json 2>$null | ConvertFrom-Json
        $namespaceId = az eventhubs namespace show -g $ResourceGroup -n $EventHubNamespaceName --query id -o tsv 2>$null
        $assignments = az role assignment list --assignee $identity.principalId --scope $namespaceId -o json 2>$null | ConvertFrom-Json
        $assignments.roleDefinitionName | Should -Contain 'Azure Event Hubs Data Sender'
    }
}

Describe 'Blob upload triggers an event (functional regression)' {

    BeforeAll {
        function Get-BicepParamValue {
            param([string]$Content, [string]$Name)
            if ($Content -match "param $Name\s*=\s*'([^']+)'") { return $Matches[1] }
            throw "Could not find parameter '$Name' in the parameter file"
        }

        $paramContent = Get-Content $ParameterFile -Raw
        $StorageAccountName = Get-BicepParamValue $paramContent 'storageAccountName'
    }

    It 'uploading a blob matching the event subscription filter succeeds and is visible in the container' {
        # Smoke-level functional check: upload a tiny throwaway blob matching the
        # subject filter configured on the event subscription (prefix +
        # '.Avro' suffix). This intentionally avoids depending on ADX
        # ingestion latency (which can take minutes) and instead confirms the
        # trigger path (blob landing in the watched container) is reachable
        # end-to-end with the pipeline's own credentials.
        $blobName = "itp-eventhub-inqtracking-dev/regression-$(Get-Date -Format 'yyyyMMddHHmmss').Avro"
        $tempFile = New-TemporaryFile
        'regression-test' | Out-File -FilePath $tempFile -Encoding ascii

        # Data-plane blob writes need either a data-plane RBAC role (Storage
        # Blob Data Contributor) or shared-key access. The CI pipeline's
        # identity only needs control-plane Contributor, so fall back to key
        # auth here (the storage account allows shared key access).
        az storage blob upload --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName -f $tempFile.FullName --overwrite true | Out-Null
        Remove-Item $tempFile -ErrorAction SilentlyContinue

        $uploaded = az storage blob show --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName -o json 2>$null | ConvertFrom-Json
        $uploaded | Should -Not -BeNullOrEmpty

        # Clean up so repeated regression runs don't accumulate test blobs.
        az storage blob delete --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName | Out-Null
    }
}
