Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalProperty {
    param([object]$InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-EnvironmentMinimumMembers {
    param([string]$Environment, [hashtable]$Sizing)
    switch ($Environment) {
        'Prod' { return [int]$Sizing.ProdMinimumMembers }
        'UAT' {
            if ($Sizing.UatReleaseCritical) { return [math]::Max(2, [int]$Sizing.UatMinimumMembers) }
            return [int]$Sizing.UatMinimumMembers
        }
        default { return [int]$Sizing.NonProdMinimumMembers }
    }
}

function Get-GatewayMemberRecommendation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$WorkloadSummary,
        [Parameter(Mandatory)][hashtable]$Sizing,
        [object[]]$SemanticModels
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($workload in $WorkloadSummary) {
        $maximumObservedPeakMemoryMB = Get-OptionalProperty $workload 'MaximumObservedPeakMemoryMB'
        $weightedDemand = [double]$workload.PercentileConcurrentRefreshes * (1 + ([double]$Sizing.HeadroomPercent / 100))
        $refreshMembers = [math]::Ceiling($weightedDemand / [double]$Sizing.RefreshSlotsPerMember)
        $directQueryCount = @($SemanticModels | Where-Object {
            $_.Environment -eq $workload.Environment -and $_.StorageMode -match 'DirectQuery|Dual|Mixed'
        }).Count
        $directQueryMembers = if ($directQueryCount -gt 0) {
            [math]::Ceiling($directQueryCount / [double]$Sizing.DirectQuerySlotsPerMember)
        } else { 0 }
        $minimum = Get-EnvironmentMinimumMembers -Environment $workload.Environment -Sizing $Sizing
        $base = [math]::Max($minimum, [math]::Max($refreshMembers, $directQueryMembers))
        $maximum = [int]$Sizing.MaximumMembersPerCluster
        $rows.Add([pscustomobject]@{
            Environment = $workload.Environment
            LowMembers = [math]::Min($maximum, $minimum)
            BaseMembers = [math]::Min($maximum, $base)
            HighMembers = [math]::Min($maximum, [math]::Max($base + 1, $minimum))
            RefreshDemandWithHeadroom = [math]::Round($weightedDemand, 2)
            RefreshSlotsPerMember = $Sizing.RefreshSlotsPerMember
            DirectQueryModelCount = $directQueryCount
            ExceedsClusterMaximum = ($base -gt $maximum)
            SingleQueryMemoryRisk = ($null -ne $maximumObservedPeakMemoryMB -and [double]$maximumObservedPeakMemoryMB -ge 8192)
            MaximumObservedPeakMemoryMB = $maximumObservedPeakMemoryMB
            Confidence = if ([int]$workload.RefreshCount -ge 30) { 'Medium' } else { 'Low' }
            Rationale = "max(HA floor $minimum, refresh members $refreshMembers, DirectQuery allowance $directQueryMembers)"
        })
    }
    return $rows.ToArray()
}

function Get-GatewayTopologyScenarios {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$MemberRecommendations,
        [Parameter(Mandatory)][hashtable]$Sizing
    )

    $lookup = @{}
    foreach ($row in $MemberRecommendations) { $lookup[$row.Environment] = $row }
    $scenarios = @(
        @{ Name = 'Prod + Shared DevQA/UAT'; Clusters = @{ Prod = @('Prod'); NonProd = @('Dev', 'QA', 'UAT') } }
        @{ Name = 'Prod + Shared DevQA + UAT'; Clusters = @{ Prod = @('Prod'); DevQA = @('Dev', 'QA'); UAT = @('UAT') } }
        @{ Name = 'Separate Environments'; Clusters = @{ Prod = @('Prod'); Dev = @('Dev'); QA = @('QA'); UAT = @('UAT') } }
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($scenario in $scenarios) {
        foreach ($clusterName in $scenario.Clusters.Keys) {
            $environments = @($scenario.Clusters[$clusterName])
            $recommendations = @($environments | Where-Object { $lookup.ContainsKey($_) } | ForEach-Object { $lookup[$_] })
            if ($recommendations.Count -eq 0) { continue }
            $refreshDemand = ($recommendations.RefreshDemandWithHeadroom | Measure-Object -Sum).Sum
            $refreshMembers = [math]::Ceiling($refreshDemand / [double]$Sizing.RefreshSlotsPerMember)
            $directQueryModels = ($recommendations.DirectQueryModelCount | Measure-Object -Sum).Sum
            $directQueryMembers = [math]::Ceiling($directQueryModels / [double]$Sizing.DirectQuerySlotsPerMember)
            $haFloor = ($recommendations.LowMembers | Measure-Object -Maximum).Maximum
            $baseMembers = [math]::Max($haFloor, [math]::Max($refreshMembers, $directQueryMembers))
            $rows.Add([pscustomobject]@{
                Scenario = $scenario.Name
                Cluster = $clusterName
                Environments = $environments -join '+'
                BaseMembers = [math]::Min([int]$Sizing.MaximumMembersPerCluster, $baseMembers)
                RefreshDemandWithHeadroom = [math]::Round($refreshDemand, 2)
                ExceedsClusterMaximum = ($baseMembers -gt [int]$Sizing.MaximumMembersPerCluster)
                RequiresNetworkValidation = ($environments.Count -gt 1)
                ProdDedicated = (-not ($environments -contains 'Prod') -or $environments.Count -eq 1)
            })
        }
    }
    return $rows.ToArray()
}

Export-ModuleMember -Function Get-GatewayMemberRecommendation, Get-GatewayTopologyScenarios
