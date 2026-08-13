Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultSkuCu = [ordered]@{
    F2 = 2; F4 = 4; F8 = 8; F16 = 16; F32 = 32; F64 = 64
    F128 = 128; F256 = 256; F512 = 512; F1024 = 1024; F2048 = 2048
    A4 = 8; A5 = 16; A6 = 32
    P1 = 64; P2 = 128; P3 = 256; P4 = 512; P5 = 1024
}

function Get-CapacityUnits {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Sku, [hashtable]$Overrides)
    if ($Overrides -and $Overrides.ContainsKey($Sku)) { return [double]$Overrides[$Sku] }
    if ($script:DefaultSkuCu.Contains($Sku)) { return [double]$script:DefaultSkuCu[$Sku] }
    return 0
}

function Get-NextCapacitySku {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$RequiredCu, [string[]]$EligibleSkus, [hashtable]$Overrides)
    $candidates = foreach ($sku in $EligibleSkus) {
        [pscustomobject]@{ Sku = $sku; Cu = Get-CapacityUnits -Sku $sku -Overrides $Overrides }
    }
    return $candidates | Where-Object { $_.Cu -ge $RequiredCu } | Sort-Object Cu | Select-Object -First 1
}

function Get-CapacityPlacementRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$TopologyRows,
        [Parameter(Mandatory)][object[]]$CapacityInventory,
        [Parameter(Mandatory)][object[]]$UtilizationBaseline,
        [Parameter(Mandatory)][hashtable]$Sizing,
        [string[]]$EligibleSkus = @('F2', 'F4', 'F8', 'F16', 'F32', 'F64', 'F128', 'F256', 'F512', 'F1024'),
        [hashtable]$SkuCuOverrides
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($topology in $TopologyRows) {
        $environments = @($topology.Environments -split '\+')
        $candidateCapacities = @($CapacityInventory | Where-Object { $_.Environment -in $environments })
        if ($candidateCapacities.Count -eq 0) { $candidateCapacities = @($null) }

        foreach ($capacity in $candidateCapacities) {
            $baseline = if ($capacity) {
                $UtilizationBaseline | Where-Object CapacityId -eq $capacity.CapacityId | Select-Object -First 1
            } else { $null }
            $currentCu = if ($capacity) { Get-CapacityUnits -Sku $capacity.Sku -Overrides $SkuCuOverrides } else { 0 }
            $baselinePercent = if ($baseline) { [double]$baseline.P95UtilizationPercent } else { 0 }
            $baselineCu = $currentCu * ($baselinePercent / 100)

            foreach ($case in 'Low', 'Base', 'High') {
                $uptimeFraction = [double]$Sizing.GatewayUptimeFraction[$case]
                $queryCu = [double]$Sizing.GatewayQueryCuPerActiveMember[$case]
                $gatewayCu = ([double]$topology.BaseMembers * 4 * $uptimeFraction) + ([double]$topology.BaseMembers * $queryCu * $uptimeFraction)
                $requiredCu = if ([double]$Sizing.CapacityTargetUtilizationPercent -gt 0) {
                    ($baselineCu + $gatewayCu) / ([double]$Sizing.CapacityTargetUtilizationPercent / 100)
                } else { $baselineCu + $gatewayCu }
                $nextSku = Get-NextCapacitySku -RequiredCu $requiredCu -EligibleSkus $EligibleSkus -Overrides $SkuCuOverrides
                $existingFits = ($currentCu -gt 0 -and $requiredCu -le $currentCu)
                $action = if (-not $capacity) {
                    'Purchase dedicated capacity'
                } elseif (-not $baseline) {
                    'Insufficient evidence/pilot required'
                } elseif ($existingFits) {
                    'No change'
                } elseif ($nextSku) {
                    'Scale existing capacity'
                } else {
                    'Purchase dedicated capacity'
                }
                $dedicatedSku = Get-NextCapacitySku -RequiredCu ($gatewayCu / ([double]$Sizing.CapacityTargetUtilizationPercent / 100)) -EligibleSkus $EligibleSkus -Overrides $SkuCuOverrides
                $rows.Add([pscustomobject]@{
                Scenario = $topology.Scenario
                Cluster = $topology.Cluster
                Environments = $topology.Environments
                SensitivityCase = $case
                ExistingCapacityId = if ($capacity) { $capacity.CapacityId } else { '' }
                ExistingCapacityName = if ($capacity) { $capacity.CapacityName } else { '' }
                ExistingSku = if ($capacity) { $capacity.Sku } else { '' }
                ExistingCapacityCu = $currentCu
                BaselineP95UtilizationPercent = if ($baseline) { $baselinePercent } else { $null }
                GatewayMembers = $topology.BaseMembers
                ProjectedGatewayAverageCu = [math]::Round($gatewayCu, 2)
                RequiredCapacityCuAtTarget = [math]::Round($requiredCu, 2)
                ExistingCapacityAction = $action
                RecommendedExistingCapacitySku = if ($existingFits) {
                    $capacity.Sku
                } elseif ($nextSku) { $nextSku.Sku } else { '' }
                DedicatedCapacitySku = if ($dedicatedSku) { $dedicatedSku.Sku } else { '' }
                RequiresPilot = ($case -ne 'Low' -or -not $baseline)
                })
            }
        }
    }
    return $rows.ToArray()
}

Export-ModuleMember -Function Get-CapacityUnits, Get-NextCapacitySku, Get-CapacityPlacementRecommendations
