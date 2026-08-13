$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\WorkloadAnalysis.psm1') -Force
Import-Module (Join-Path $root 'src\GatewaySizing.psm1') -Force
Import-Module (Join-Path $root 'src\CapacityAnalysis.psm1') -Force
Import-Module (Join-Path $root 'src\RefreshHistory.psm1') -Force

Describe 'Gateway sizing' {
    BeforeAll {
        $sizing = @{
            RefreshSlotsPerMember = 6
            DirectQuerySlotsPerMember = 15
            MaximumMembersPerCluster = 9
            HeadroomPercent = 25
            ProdMinimumMembers = 2
            UatMinimumMembers = 1
            NonProdMinimumMembers = 1
            UatReleaseCritical = $false
            CapacityTargetUtilizationPercent = 80
            GatewayUptimeFraction = @{ Low = .25; Base = .5; High = 1 }
            GatewayQueryCuPerActiveMember = @{ Low = 0; Base = 2; High = 4 }
        }
    }

    It 'applies the production HA floor' {
        $result = Get-GatewayMemberRecommendation -WorkloadSummary @(
            [pscustomobject]@{ Environment='Prod'; PercentileConcurrentRefreshes=1; RefreshCount=100 }
        ) -Sizing $sizing -SemanticModels @()
        if ($result[0].BaseMembers -ne 2) { throw "Expected 2 members, got $($result[0].BaseMembers)." }
    }

    It 'selects the next sufficient Fabric SKU' {
        $result = Get-NextCapacitySku -RequiredCu 20 -EligibleSkus @('F8','F16','F32')
        if ($result.Sku -ne 'F32') { throw "Expected F32, got $($result.Sku)." }
    }

    It 'calculates a percentile' {
        $actual = Get-Percentile -Values @(1, 2, 3, 4, 5) -Percentile 50
        if ($actual -ne 3) { throw "Expected 3, got $actual." }
    }

    It 'adds shared cluster refresh demand' {
        $recommendations = @(
            [pscustomobject]@{ Environment='Dev'; LowMembers=1; BaseMembers=1; RefreshDemandWithHeadroom=5; DirectQueryModelCount=0 }
            [pscustomobject]@{ Environment='QA'; LowMembers=1; BaseMembers=1; RefreshDemandWithHeadroom=5; DirectQueryModelCount=0 }
        )
        $result = Get-GatewayTopologyScenarios -MemberRecommendations $recommendations -Sizing $sizing |
            Where-Object { $_.Scenario -eq 'Prod + Shared DevQA + UAT' -and $_.Cluster -eq 'DevQA' }
        if ($result.BaseMembers -ne 2) { throw "Expected shared cluster to require 2 members, got $($result.BaseMembers)." }
    }

    It 'evaluates each eligible existing capacity for a shared cluster' {
        $topology = @([pscustomobject]@{
            Scenario='Shared'; Cluster='DevQA'; Environments='Dev+QA'; BaseMembers=2
        })
        $capacities = @(
            [pscustomobject]@{ CapacityId='dev'; CapacityName='Dev'; Environment='Dev'; Sku='F8' }
            [pscustomobject]@{ CapacityId='qa'; CapacityName='QA'; Environment='QA'; Sku='F16' }
        )
        $baseline = @(
            [pscustomobject]@{ CapacityId='dev'; P95UtilizationPercent=50 }
            [pscustomobject]@{ CapacityId='qa'; P95UtilizationPercent=50 }
        )
        $result = @(Get-CapacityPlacementRecommendations -TopologyRows $topology -CapacityInventory $capacities -UtilizationBaseline $baseline -Sizing $sizing)
        if ($result.Count -ne 6) { throw "Expected 6 sensitivity rows across 2 capacity candidates, got $($result.Count)." }
    }

    It 'imports retained historical refresh rows' {
        $path = Join-Path $TestDrive 'retained-refresh.csv'
        @([pscustomobject]@{
            WorkspaceId='w1'; SemanticModelId='d1'; StartTimeUtc='2026-01-01T00:00:00Z'
            RequestId='r1'; RefreshType='ViaApi'
        }) | Export-Csv $path -NoTypeInformation
        $result = @(Import-RetainedRefreshHistory -Paths @($path))
        if ($result.Count -ne 1 -or $result[0].HistorySource -notlike 'Imported:*') {
            throw 'Retained refresh history was not imported correctly.'
        }
    }
}
