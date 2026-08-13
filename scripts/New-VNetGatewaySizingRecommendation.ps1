[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [string]$CapacityUtilizationPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\WorkloadAnalysis.psm1') -Force
Import-Module (Join-Path $root 'src\GatewaySizing.psm1') -Force
Import-Module (Join-Path $root 'src\CapacityAnalysis.psm1') -Force

$configuration = Import-PowerShellDataFile -Path (Resolve-Path $ConfigurationPath)
$outputPath = $configuration.OutputPath
if (-not [IO.Path]::IsPathRooted($outputPath)) { $outputPath = Join-Path $root $outputPath }

$refreshPath = Join-Path $outputPath 'refresh-history.csv'
$modelsPath = Join-Path $outputPath 'semantic-models.csv'
$capacityPath = Join-Path $outputPath 'capacity-inventory.csv'
foreach ($path in $refreshPath, $modelsPath, $capacityPath) {
    if (-not (Test-Path $path)) { throw "Missing required inventory output: $path" }
}

$refreshRows = @(Import-Csv $refreshPath | ForEach-Object {
    $_.StartTimeUtc = if ($_.StartTimeUtc) { [datetime]$_.StartTimeUtc } else { $null }
    $_.EndTimeUtc = if ($_.EndTimeUtc) { [datetime]$_.EndTimeUtc } else { $null }
    $_
})
$models = @(Import-Csv $modelsPath)
$capacities = @(Import-Csv $capacityPath)
$utilization = if ($CapacityUtilizationPath -and (Test-Path $CapacityUtilizationPath)) {
    @(Import-Csv $CapacityUtilizationPath)
} else {
    $templatePath = Join-Path $outputPath 'capacity-utilization-baseline-template.csv'
    $capacities | Select-Object CapacityId, CapacityName, @{Name='P95UtilizationPercent';Expression={''}},
        @{Name='PeakUtilizationPercent';Expression={''}}, @{Name='InteractiveDelayCount';Expression={''}},
        @{Name='BackgroundRejectionCount';Expression={''}} |
        Export-Csv -Path $templatePath -NoTypeInformation -Encoding utf8
    @()
}

$concurrency = @(Get-RefreshConcurrencySeries -RefreshRows $refreshRows)
$batches = @(Get-RefreshBatchSummary -RefreshRows $refreshRows -BatchWindowMinutes $configuration.Sizing.BatchWindowMinutes)
$summary = @(Get-EnvironmentWorkloadSummary -RefreshRows $refreshRows -ConcurrencyRows $concurrency -Percentile $configuration.Sizing.Percentile)
$members = @(Get-GatewayMemberRecommendation -WorkloadSummary $summary -Sizing $configuration.Sizing -SemanticModels $models)
$topologies = @(Get-GatewayTopologyScenarios -MemberRecommendations $members -Sizing $configuration.Sizing)
$capacityActions = @(Get-CapacityPlacementRecommendations -TopologyRows $topologies -CapacityInventory $capacities -UtilizationBaseline $utilization -Sizing $configuration.Sizing)

$concurrency | Export-Csv (Join-Path $outputPath 'refresh-concurrency.csv') -NoTypeInformation -Encoding utf8
$batches | Export-Csv (Join-Path $outputPath 'refresh-batches.csv') -NoTypeInformation -Encoding utf8
$summary | Export-Csv (Join-Path $outputPath 'estate-summary.csv') -NoTypeInformation -Encoding utf8
$members | Export-Csv (Join-Path $outputPath 'gateway-sizing-recommendations.csv') -NoTypeInformation -Encoding utf8
$topologies | Export-Csv (Join-Path $outputPath 'gateway-topology-scenarios.csv') -NoTypeInformation -Encoding utf8
$capacityActions | Export-Csv (Join-Path $outputPath 'capacity-actions.csv') -NoTypeInformation -Encoding utf8

Write-Host "Sizing recommendations complete: $outputPath"
