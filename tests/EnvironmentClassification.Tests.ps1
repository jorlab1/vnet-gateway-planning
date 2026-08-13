$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Inventory.psm1') -Force

Describe 'Resolve-EstateEnvironment' {
    BeforeAll {
        $rules = @(
            @{ Environment = 'Prod'; Pattern = '(?i)prod' }
            @{ Environment = 'Dev'; Pattern = '(?i)dev' }
        )
    }

    It 'classifies a capacity with one matching rule' {
        $actual = Resolve-EstateEnvironment -CapacityName 'finance-prod-f64' -Rules $rules
        if ($actual -ne 'Prod') { throw "Expected Prod, got $actual." }
    }

    It 'returns Unclassified for ambiguous names' {
        $actual = Resolve-EstateEnvironment -CapacityName 'dev-prod-shared' -Rules $rules
        if ($actual -ne 'Unclassified') { throw "Expected Unclassified, got $actual." }
    }

    It 'prefers an explicit mapping' {
        $actual = Resolve-EstateEnvironment -CapacityName 'special' -Rules $rules -ExplicitNameMap @{ special = 'UAT' }
        if ($actual -ne 'UAT') { throw "Expected UAT, got $actual." }
    }

    It 'supports an exact capacity ID mapping' {
        $actual = Resolve-EstateEnvironment -CapacityName 'No Useful Pattern' -CapacityId 'capacity-123' `
            -Rules $rules -ExplicitIdMap @{ 'capacity-123' = 'Prod' }
        if ($actual -ne 'Prod') { throw "Expected Prod, got $actual." }
    }

    It 'prefers capacity ID over a conflicting name mapping' {
        $actual = Resolve-EstateEnvironment -CapacityName 'Blue Capacity' -CapacityId 'capacity-123' `
            -Rules $rules -ExplicitNameMap @{ 'Blue Capacity' = 'Dev' } `
            -ExplicitIdMap @{ 'capacity-123' = 'QA' }
        if ($actual -ne 'QA') { throw "Expected QA, got $actual." }
    }

    It 'handles omitted optional scanner properties' {
        $scan = @('{"workspaces":[{"id":"w1","name":"Dev","capacityId":"c1","datasets":[{"id":"d1","name":"Model"}]}]}' | ConvertFrom-Json)
        $result = ConvertTo-EstateInventory -ScanResults $scan -CapacityLookup @{
            c1 = [pscustomobject]@{ DisplayName = 'team-dev' }
        } -EnvironmentRules $rules
        if ($result.SemanticModels.Count -ne 1 -or $result.SemanticModels[0].StorageMode -ne 'Unknown') {
            throw 'Optional scanner properties were not handled safely.'
        }
    }
}
