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

Describe 'Blob upload triggers ADX ingestion end-to-end (functional regression)' {

    BeforeAll {
        function Get-BicepParamValue {
            param([string]$Content, [string]$Name)
            if ($Content -match "param $Name\s*=\s*'([^']+)'") { return $Matches[1] }
            throw "Could not find parameter '$Name' in the parameter file"
        }

        $paramContent = Get-Content $ParameterFile -Raw
        $StorageAccountName = Get-BicepParamValue $paramContent 'storageAccountName'
        $KustoClusterName = Get-BicepParamValue $paramContent 'kustoClusterName'

        # These must stay in sync with the defaults in infra/modules/kusto.bicep
        # and the table/mapping created by
        # adx/scripts/clf-events_capture_ingestion_tables.kql - neither the
        # database name nor the ingestion table name is exposed as a
        # top-level main.bicep parameter (same as the event hub/consumer
        # group names already hardcoded further up in this file).
        $IngestionDatabaseName = 'clf-event-capture'
        $IngestionTableName = 'clf_events_capture_blobs_avro'
        $SampleAvroFilePath = (Resolve-Path "$PSScriptRoot\..\sampledata\32.avro").Path

        # The ingestion batching policy set by the KQL script batches for up
        # to 2 minutes (MaximumBatchingTimeSpan: 00:02:00) before Kusto even
        # attempts to pull a newly arrived blob, so polling must comfortably
        # exceed that window to avoid false negatives.
        $script:IngestionPollIntervalSeconds = 20
        $script:IngestionMaxWaitSeconds = 360

        $script:KustoClusterUri = az kusto cluster show -g $ResourceGroup -n $KustoClusterName --query uri -o tsv --only-show-errors
        if ([string]::IsNullOrWhiteSpace($script:KustoClusterUri)) {
            throw "Could not resolve the query URI for Kusto cluster '$KustoClusterName' in resource group '$ResourceGroup'."
        }

        function Get-KustoAccessToken {
            param([string]$ClusterUri)
            $token = az account get-access-token --resource $ClusterUri --query accessToken -o tsv --only-show-errors
            if ([string]::IsNullOrWhiteSpace($token)) {
                throw "Could not acquire an access token for Kusto cluster '$ClusterUri'. Ensure 'az login' is active on this runner."
            }
            return $token
        }

        function ConvertFrom-KustoV1Result {
            param($Response)
            $table = $Response.Tables[0]
            $columnNames = @($table.Columns | ForEach-Object { $_.ColumnName })
            foreach ($row in @($table.Rows)) {
                $obj = [ordered]@{}
                for ($i = 0; $i -lt $columnNames.Count; $i++) {
                    $obj[$columnNames[$i]] = $row[$i]
                }
                [PSCustomObject]$obj
            }
        }

        # Runs a read-only KQL query (e.g. 'TableName | where ...').
        function Invoke-KustoQuery {
            param([string]$ClusterUri, [string]$Database, [string]$Query)
            $token = Get-KustoAccessToken -ClusterUri $ClusterUri
            $body = @{ db = $Database; csl = $Query } | ConvertTo-Json
            $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
            $response = Invoke-RestMethod -Uri "$ClusterUri/v1/rest/query" -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body
            return ConvertFrom-KustoV1Result -Response $response
        }

        # Runs a Kusto management/control command (e.g. '.show ...', '.delete ...').
        function Invoke-KustoManagementCommand {
            param([string]$ClusterUri, [string]$Database, [string]$Command)
            $token = Get-KustoAccessToken -ClusterUri $ClusterUri
            $body = @{ db = $Database; csl = $Command } | ConvertTo-Json
            $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
            $response = Invoke-RestMethod -Uri "$ClusterUri/v1/rest/mgmt" -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body
            return ConvertFrom-KustoV1Result -Response $response
        }
    }

    It 'uploading the sample Avro blob is ingested into ADX (verified via sourceLocation) before cleanup' {
        # Functional check: upload a real Event-Hub-Capture-format Avro file
        # (matching the subject filter configured on the event subscription -
        # prefix + '.Avro' suffix) and confirm it is actually ingested by the
        # ADX data connection, not just that the blob landed in the
        # container. The blob is deliberately kept in place until ingestion
        # is confirmed (or the wait times out) - deleting it immediately, as
        # a prior version of this test did, causes ADX to fail ingestion with
        # "Download_SourceNotFound" since ingestion is asynchronous/batched.
        $blobName = "itp-eventhub-inqtracking-dev/regression-$(Get-Date -Format 'yyyyMMddHHmmss').Avro"

        # Data-plane blob writes need either a data-plane RBAC role (Storage
        # Blob Data Contributor) or shared-key access. The CI pipeline's
        # identity only needs control-plane Contributor, so fall back to key
        # auth here (the storage account allows shared key access).
        az storage blob upload --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName -f $SampleAvroFilePath --overwrite true | Out-Null

        $uploaded = az storage blob show --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName -o json 2>$null | ConvertFrom-Json
        $uploaded | Should -Not -BeNullOrEmpty

        $blobUrl = az storage blob url --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName -o tsv

        try {
            $ingestedRows = @()
            $elapsedSeconds = 0
            while ($elapsedSeconds -le $script:IngestionMaxWaitSeconds) {
                $query = "$IngestionTableName | where sourceLocation contains '$blobName' | take 10"
                $ingestedRows = @(Invoke-KustoQuery -ClusterUri $script:KustoClusterUri -Database $IngestionDatabaseName -Query $query)
                if ($ingestedRows.Count -gt 0) { break }
                Start-Sleep -Seconds $script:IngestionPollIntervalSeconds
                $elapsedSeconds += $script:IngestionPollIntervalSeconds
            }

            if ($ingestedRows.Count -eq 0) {
                # Surface actual ingestion failures for this specific blob (if
                # any) to make root-causing a real pipeline break far faster
                # than just "no rows found".
                $failureQuery = ".show ingestion failures | where IngestionSourcePath contains '$blobName'"
                $failures = @(Invoke-KustoManagementCommand -ClusterUri $script:KustoClusterUri -Database $IngestionDatabaseName -Command $failureQuery)
                $failureSummary = if ($failures.Count -gt 0) {
                    ($failures | ForEach-Object { "[$($_.FailedOn)] $($_.ErrorCode): $($_.Details)" }) -join "`n"
                } else {
                    "No matching '.show ingestion failures' entries were found either - the batch may still be in flight, or the data connection may be misconfigured."
                }
                throw "Blob '$blobUrl' was not ingested into '$IngestionTableName' within $($script:IngestionMaxWaitSeconds)s.`n$failureSummary"
            }

            $ingestedRows.Count | Should -BeGreaterThan 0
            $ingestedRows[0].sourceLocation | Should -Match ([regex]::Escape($blobName))
        }
        finally {
            # Clean up regardless of outcome (pass, fail, or timeout) so
            # repeated regression runs don't accumulate test blobs or ADX
            # records. Each step is independently wrapped so one failing
            # doesn't skip the other, and failures are surfaced as warnings
            # (not thrown) so a cleanup hiccup doesn't mask the test's actual
            # pass/fail result for ingestion itself - but is still visible in
            # the test log for investigation.
            try {
                $deleteRecordsQuery = ".delete table $IngestionTableName records <| $IngestionTableName | where sourceLocation contains '$blobName'"
                $deleteResult = Invoke-KustoManagementCommand -ClusterUri $script:KustoClusterUri -Database $IngestionDatabaseName -Command $deleteRecordsQuery
                Write-Host "Deleted $($deleteResult[0].RecordsMatchPredicate) ADX record(s) matching '$blobName'."
            } catch {
                Write-Warning "Failed to delete ADX records for '$blobName': $_"
            }

            try {
                az storage blob delete --account-name $StorageAccountName --auth-mode key --only-show-errors -c 'clf' -n $blobName | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "az storage blob delete for '$blobName' exited with code $LASTEXITCODE."
                }
            } catch {
                Write-Warning "Failed to delete blob '$blobName': $_"
            }
        }
    }
}

