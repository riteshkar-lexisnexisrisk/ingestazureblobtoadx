<#
.SYNOPSIS
    Unit tests for the infra-as-code templates. These run in seconds, require no
    Azure deployment, and are executed on every Pull Request before anything is
    promoted to SharedDev.
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $script:InfraRoot = Join-Path $RepoRoot 'infra'
    $script:MainBicep = Join-Path $InfraRoot 'main.bicep'
    $script:ParamFiles = Get-ChildItem (Join-Path $InfraRoot 'parameters') -Filter '*.bicepparam'
}

Describe 'Bicep templates compile cleanly' {

    BeforeAll {
        $RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
        $InfraRoot = Join-Path $RepoRoot 'infra'
        $MainBicep = Join-Path $InfraRoot 'main.bicep'
    }

    It 'builds main.bicep without errors' {
        $output = az bicep build --file $MainBicep --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }

    It 'builds every module without errors' -ForEach (Get-ChildItem (Join-Path $InfraRoot 'modules') -Filter '*.bicep') {
        $output = az bicep build --file $_.FullName --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }
}

Describe 'Environment parameter files' {

    BeforeAll {
        $RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
        $InfraRoot = Join-Path $RepoRoot 'infra'
        $ParamFiles = Get-ChildItem (Join-Path $InfraRoot 'parameters') -Filter '*.bicepparam'
    }

    It 'has a parameter file for shareddev and test environments' {
        $names = $ParamFiles.BaseName
        $names | Should -Contain 'shareddev'
        $names | Should -Contain 'test'
    }

    It 'builds <_.Name> without errors' -ForEach $script:ParamFiles {
        $output = az bicep build-params --file $_.FullName --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }

    It '<_.Name> declares a globally-unique storage account name' -ForEach $script:ParamFiles {
        $content = Get-Content $_.FullName -Raw
        $content | Should -Match "param storageAccountName\s*=\s*'[a-z0-9]{3,24}'"
    }

    It 'shareddev and test environments do not share a storage account name' {
        $sharedDevContent = Get-Content ($ParamFiles | Where-Object BaseName -eq 'shareddev').FullName -Raw
        $testContent = Get-Content ($ParamFiles | Where-Object BaseName -eq 'test').FullName -Raw

        function Get-StorageAccountName($content) {
            if ($content -match "param storageAccountName\s*=\s*'([a-z0-9]{3,24})'") { return $Matches[1] }
            return $null
        }

        Get-StorageAccountName $sharedDevContent | Should -Not -Be (Get-StorageAccountName $testContent)
    }
}

Describe 'Resource naming conventions' {

    BeforeAll {
        $RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
        $MainBicepContent = Get-Content (Join-Path $RepoRoot 'infra\main.bicep') -Raw
    }

    It 'tags every environment resource with environmentName' {
        $MainBicepContent | Should -Match 'environment:\s*environmentName'
    }

    It 'grants the ADX identity Storage Blob Data Reader on the storage account' {
        $MainBicepContent | Should -Match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    }

    It 'grants the ADX identity Azure Event Hubs Data Receiver on the namespace' {
        $MainBicepContent | Should -Match 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
    }

    It 'grants the Event Grid identity Azure Event Hubs Data Sender on the namespace' {
        $MainBicepContent | Should -Match '2b629674-e913-4c01-ae53-ef4638d8f975'
    }
}
