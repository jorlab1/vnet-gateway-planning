$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\TenantInventory.psm1') -Force

function New-TestScan {
    param([object[]]$Workspaces)
    return [pscustomobject]@{ workspaces = $Workspaces }
}

function New-TestWorkspace {
    param([string]$Id, [string]$Name, [string]$CapacityId, [object[]]$Datasets = @())
    $workspace = [pscustomobject]@{ id = $Id; name = $Name; datasets = $Datasets }
    if ($PSBoundParameters.ContainsKey('CapacityId')) {
        $workspace | Add-Member -NotePropertyName capacityId -NotePropertyValue $CapacityId
    }
    return $workspace
}

function New-TestDataset {
    param([string]$Id, [string]$Name, [string]$CreatedDate, [string]$TargetStorageMode = 'Abf')
    return [pscustomobject]@{
        id = $Id
        name = $Name
        createdDate = $CreatedDate
        targetStorageMode = $TargetStorageMode
    }
}

$capacities = @(
    [pscustomobject]@{ id = 'cap-1'; displayName = 'Alpha Capacity'; state = 'Active' }
    [pscustomobject]@{ id = 'cap-2'; displayName = 'Beta Capacity'; state = 'Suspended' }
)

Describe 'Inventory CSV contract' {
    It 'emits exactly the requested columns in order' {
        $expected = @('CapacityName', 'CapacityId', 'WorkspaceName', 'WorkspaceId', 'SemanticModelName', 'SemanticModelCreatedAt', 'TargetStorageMode')
        $actual = @(Get-InventoryColumnName)
        if (($actual -join ',') -ne ($expected -join ',')) {
            throw "Unexpected column contract: $($actual -join ',')"
        }

        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Model' -CreatedDate '2026-01-01T10:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        $row = @(ConvertTo-InventoryCsvRow -Rows $result.Rows)[0]
        $names = @($row.PSObject.Properties.Name)
        if (($names -join ',') -ne ($expected -join ',')) {
            throw "Projected row columns were $($names -join ',')."
        }
    }

    It 'writes creation timestamps as UTC ISO 8601' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Model' -CreatedDate '2026-01-01T10:00:00-05:00'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        $row = @(ConvertTo-InventoryCsvRow -Rows $result.Rows)[0]
        if ($row.SemanticModelCreatedAt -notlike '2026-01-01T15:00:00*Z') {
            throw "Expected a normalized UTC timestamp, got $($row.SemanticModelCreatedAt)."
        }
    }

    It 'resolves capacity names and keeps suspended capacities' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w2' -Name 'Finance' -CapacityId 'cap-2' -Datasets @(
                New-TestDataset -Id 'd2' -Name 'Model' -CreatedDate '2026-01-01T10:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if ($result.Rows[0].CapacityName -ne 'Beta Capacity') {
            throw "Expected the suspended capacity to be inventoried, got '$($result.Rows[0].CapacityName)'."
        }
    }
}

Describe 'Semantic model deduplication' {
    It 'keeps the most recently created duplicate in a workspace' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'old' -Name 'Revenue' -CreatedDate '2025-01-01T00:00:00Z'
                New-TestDataset -Id 'new' -Name 'Revenue' -CreatedDate '2026-05-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if ($result.Rows.Count -ne 1) { throw "Expected 1 row, got $($result.Rows.Count)." }
        if ($result.Rows[0].SemanticModelId -ne 'new') { throw "Expected the newest model, got $($result.Rows[0].SemanticModelId)." }
        if ($result.DuplicateModelsResolved -ne 1) { throw "Expected 1 resolved duplicate, got $($result.DuplicateModelsResolved)." }
    }

    It 'treats duplicate names case-insensitively' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'lower' -Name 'sales model' -CreatedDate '2025-01-01T00:00:00Z'
                New-TestDataset -Id 'upper' -Name 'SALES MODEL' -CreatedDate '2026-01-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if ($result.Rows.Count -ne 1) { throw "Expected case-insensitive collapse, got $($result.Rows.Count) rows." }
        if ($result.Rows[0].SemanticModelId -ne 'upper') { throw "Expected the newest model, got $($result.Rows[0].SemanticModelId)." }
    }

    It 'breaks identical creation times deterministically by model ID' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'aaa' -Name 'Revenue' -CreatedDate '2026-01-01T00:00:00Z'
                New-TestDataset -Id 'zzz' -Name 'Revenue' -CreatedDate '2026-01-01T00:00:00Z'
            )
        )
        $first = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        $second = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if ($first.Rows[0].SemanticModelId -ne $second.Rows[0].SemanticModelId) {
            throw 'Tie-breaking was not deterministic.'
        }
        if ($first.Rows[0].SemanticModelId -ne 'zzz') {
            throw "Expected the deterministic tie-break winner 'zzz', got $($first.Rows[0].SemanticModelId)."
        }
    }

    It 'keeps identical model names that live in different workspaces' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Shared' -CreatedDate '2026-01-01T00:00:00Z'
            )
            New-TestWorkspace -Id 'w2' -Name 'Finance' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd2' -Name 'Shared' -CreatedDate '2025-01-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if ($result.Rows.Count -ne 2) {
            throw "Expected same-named models in different workspaces to be kept, got $($result.Rows.Count) rows."
        }
    }

    It 'fails when duplicates cannot be ordered by creation time' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Revenue' -CreatedDate '2026-01-01T00:00:00Z'
                New-TestDataset -Id 'd2' -Name 'Revenue' -CreatedDate ''
            )
        )
        $threw = $false
        try { ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities }
        catch { $threw = $true }
        if (-not $threw) { throw 'Expected an error for unorderable duplicates.' }
    }
}

Describe 'Workspace eligibility' {
    It 'excludes workspaces with no capacity assignment' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Assigned' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Model' -CreatedDate '2026-01-01T00:00:00Z'
            )
            New-TestWorkspace -Id 'w2' -Name 'Unassigned' -Datasets @(
                New-TestDataset -Id 'd2' -Name 'Model' -CreatedDate '2026-01-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if ($result.Rows.Count -ne 1) { throw "Expected 1 row, got $($result.Rows.Count)." }
        if ($result.SkippedWorkspaces.Count -ne 1) { throw 'Expected one skipped workspace warning.' }
        if ($result.SkippedWorkspaces[0].WorkspaceId -ne 'w2') { throw 'Wrong workspace was skipped.' }
    }

    It 'reports capacity IDs that the capacities endpoint did not return' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Orphan' -CapacityId 'cap-missing' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Model' -CreatedDate '2026-01-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        if (@($result.UnknownCapacityIds) -notcontains 'cap-missing') {
            throw 'Unknown capacity ID was not reported.'
        }
        if ($result.Rows.Count -ne 1) { throw 'The row should still be exported with a blank capacity name.' }
    }
}

Describe 'Inventory export' {
    It 'sorts rows by capacity, workspace, then model name' {
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w2' -Name 'Zulu' -CapacityId 'cap-2' -Datasets @(
                New-TestDataset -Id 'd3' -Name 'Model C' -CreatedDate '2026-01-01T00:00:00Z'
            )
            New-TestWorkspace -Id 'w1' -Name 'Alpha' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd2' -Name 'Model B' -CreatedDate '2026-01-01T00:00:00Z'
                New-TestDataset -Id 'd1' -Name 'Model A' -CreatedDate '2026-01-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        $order = @($result.Rows | ForEach-Object { $_.SemanticModelName }) -join '|'
        if ($order -ne 'Model A|Model B|Model C') { throw "Unexpected sort order: $order." }
    }

    It 'writes a header-only file when no models are found' {
        $path = Join-Path $TestDrive 'empty-inventory.csv'
        $count = Export-TenantInventoryCsv -Rows @() -Path $path
        if ($count -ne 0) { throw "Expected 0 rows, got $count." }
        $header = (Get-Content -LiteralPath $path -TotalCount 1)
        if ($header -notlike '*CapacityName*TargetStorageMode*') { throw "Unexpected header: $header." }
    }

    It 'leaves no temporary files behind after a successful export' {
        $path = Join-Path $TestDrive 'inventory.csv'
        $scan = New-TestScan -Workspaces @(
            New-TestWorkspace -Id 'w1' -Name 'Sales' -CapacityId 'cap-1' -Datasets @(
                New-TestDataset -Id 'd1' -Name 'Model' -CreatedDate '2026-01-01T00:00:00Z'
            )
        )
        $result = ConvertTo-TenantInventory -ScanResults @($scan) -Capacities $capacities
        [void](Export-TenantInventoryCsv -Rows $result.Rows -Path $path)
        $leftovers = @(Get-ChildItem -Path $TestDrive -Filter '*.tmp')
        if ($leftovers.Count -ne 0) { throw 'Temporary export files were left on disk.' }
        if (@(Import-Csv $path).Count -ne 1) { throw 'Exported CSV did not contain the expected row.' }
    }
}
