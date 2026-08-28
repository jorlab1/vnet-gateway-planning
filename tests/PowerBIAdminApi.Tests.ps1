$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\PowerBIAdminApi.psm1') -Force

Describe 'Workspace scan batching' {
    It 'splits workspaces into batches of at most 100 and scans them all' {
        Mock -ModuleName PowerBIAdminApi Start-InventoryWorkspaceScan { return 'scan-id' }
        Mock -ModuleName PowerBIAdminApi Wait-InventoryWorkspaceScan { return [pscustomobject]@{ workspaces = @() } }

        $workspaces = @(1..250 | ForEach-Object { [pscustomobject]@{ id = "w$_"; name = "Workspace $_" } })
        $results = @(Invoke-InventoryWorkspaceScan -Workspaces $workspaces -AccessToken 'token' -PollSeconds 0)

        if ($results.Count -ne 3) { throw "Expected 3 scan batches, got $($results.Count)." }
        Assert-MockCalled -ModuleName PowerBIAdminApi Start-InventoryWorkspaceScan -Times 3 -Exactly
        Assert-MockCalled -ModuleName PowerBIAdminApi Start-InventoryWorkspaceScan -Times 3 -Exactly `
            -ParameterFilter { $WorkspaceIds.Count -le 100 }
    }

    It 'does not cap the number of batches for large tenants' {
        Mock -ModuleName PowerBIAdminApi Start-InventoryWorkspaceScan { return 'scan-id' }
        Mock -ModuleName PowerBIAdminApi Wait-InventoryWorkspaceScan { return [pscustomobject]@{ workspaces = @() } }

        $workspaces = @(1..1500 | ForEach-Object { [pscustomobject]@{ id = "w$_"; name = "Workspace $_" } })
        $results = @(Invoke-InventoryWorkspaceScan -Workspaces $workspaces -AccessToken 'token' -PollSeconds 0 `
                -LargeRunBatchWarningThreshold 10000 -WarningAction SilentlyContinue)

        if ($results.Count -ne 15) { throw "Expected 15 scan batches, got $($results.Count)." }
    }

    It 'aborts the run and names the workspaces when a batch fails' {
        Mock -ModuleName PowerBIAdminApi Start-InventoryWorkspaceScan { throw 'scan rejected' }
        Mock -ModuleName PowerBIAdminApi Wait-InventoryWorkspaceScan { return [pscustomobject]@{ workspaces = @() } }

        $workspaces = @([pscustomobject]@{ id = 'w1'; name = 'Broken Workspace' })
        $threw = $false
        $message = ''
        try { Invoke-InventoryWorkspaceScan -Workspaces $workspaces -AccessToken 'token' -PollSeconds 0 }
        catch { $threw = $true; $message = $_.Exception.Message }

        if (-not $threw) { throw 'Expected a failed scan batch to abort the inventory.' }
        if ($message -notlike '*Broken Workspace*') { throw "Failure did not identify the workspace: $message" }
        if ($message -notlike '*not written*') { throw "Failure did not state that no inventory was written: $message" }
    }

    It 'returns nothing when there are no workspaces to scan' {
        $results = @(Invoke-InventoryWorkspaceScan -Workspaces @() -AccessToken 'token')
        if ($results.Count -ne 0) { throw "Expected no scan results, got $($results.Count)." }
    }
}

Describe 'Scanner request shape' {
    It 'requests only base inventory metadata' {
        Mock -ModuleName PowerBIAdminApi Invoke-InventoryAdminRequest { return [pscustomobject]@{ id = 'scan-1' } }

        $scanId = Start-InventoryWorkspaceScan -WorkspaceIds @('w1') -AccessToken 'token'
        if ($scanId -ne 'scan-1') { throw "Expected the scan ID to be returned, got $scanId." }

        Assert-MockCalled -ModuleName PowerBIAdminApi Invoke-InventoryAdminRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*lineage=false*' -and
            $Uri -like '*datasourceDetails=false*' -and
            $Uri -like '*datasetSchema=false*' -and
            $Uri -like '*datasetExpressions=false*' -and
            $Uri -like '*getArtifactUsers=false*' -and
            $Method -eq 'POST'
        }
    }
}

Describe 'Workspace discovery' {
    It 'pages the admin groups endpoint and drops deleted and personal workspaces' {
        Mock -ModuleName PowerBIAdminApi Invoke-InventoryAdminRequest {
            if ($Uri -like '*$skip=0*') {
                return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'w1'; name = 'Active'; state = 'Active'; type = 'Workspace' }
                    [pscustomobject]@{ id = 'w2'; name = 'Deleted'; state = 'Deleted'; type = 'Workspace' }
                ) }
            }
            return [pscustomobject]@{ value = @(
                [pscustomobject]@{ id = 'w3'; name = 'Personal'; state = 'Active'; type = 'PersonalGroup' }
            ) }
        }

        $workspaces = @(Get-InventoryWorkspace -AccessToken 'token' -PageSize 2)

        if ($workspaces.Count -ne 1) { throw "Expected only the active workspace, got $($workspaces.Count)." }
        if ($workspaces[0].id -ne 'w1') { throw "Unexpected workspace $($workspaces[0].id)." }
        Assert-MockCalled -ModuleName PowerBIAdminApi Invoke-InventoryAdminRequest -Times 2 -Exactly
    }
}
