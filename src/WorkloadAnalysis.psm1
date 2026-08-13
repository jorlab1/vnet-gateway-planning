Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalProperty {
    param([object]$InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-Percentile {
    [CmdletBinding()]
    param([double[]]$Values, [ValidateRange(0, 100)][double]$Percentile)
    if (-not $Values -or $Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $rank = ($Percentile / 100) * ($sorted.Count - 1)
    $lower = [math]::Floor($rank)
    $upper = [math]::Ceiling($rank)
    if ($lower -eq $upper) { return [double]$sorted[$lower] }
    return [double]$sorted[$lower] + (($rank - $lower) * ([double]$sorted[$upper] - [double]$sorted[$lower]))
}

function Get-RefreshConcurrencySeries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$RefreshRows)

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($RefreshRows | Where-Object { $_.StartTimeUtc -and $_.EndTimeUtc } | Group-Object Environment)) {
        $events = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $group.Group) {
            $events.Add([pscustomobject]@{ Time = [datetime]$row.StartTimeUtc; Delta = 1 })
            $events.Add([pscustomobject]@{ Time = [datetime]$row.EndTimeUtc; Delta = -1 })
        }
        $current = 0
        $timeGroups = @($events | Group-Object Time | Sort-Object { [datetime]$_.Name })
        for ($index = 0; $index -lt $timeGroups.Count; $index++) {
            $timeGroup = $timeGroups[$index]
            $current += ($timeGroup.Group.Delta | Measure-Object -Sum).Sum
            $start = [datetime]$timeGroup.Name
            $end = if ($index + 1 -lt $timeGroups.Count) { [datetime]$timeGroups[$index + 1].Name } else { $start }
            $result.Add([pscustomobject]@{
                Environment = $group.Name
                StartTimeUtc = $start.ToUniversalTime().ToString('o')
                EndTimeUtc = $end.ToUniversalTime().ToString('o')
                DurationSeconds = [math]::Max(0, ($end - $start).TotalSeconds)
                ConcurrentRefreshes = $current
            })
        }
    }
    return $result.ToArray()
}

function Get-RefreshBatchSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$RefreshRows,
        [int]$BatchWindowMinutes = 5
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($RefreshRows | Where-Object { $_.StartTimeUtc -and $_.RefreshType -match 'Api|Xmla' } | Group-Object Environment)) {
        $ordered = @($group.Group | Sort-Object { [datetime]$_.StartTimeUtc })
        $batch = [System.Collections.Generic.List[object]]::new()
        $batchNumber = 0
        foreach ($row in $ordered) {
            if ($batch.Count -eq 0 -or (([datetime]$row.StartTimeUtc) - ([datetime]$batch[-1].StartTimeUtc)).TotalMinutes -le $BatchWindowMinutes) {
                $batch.Add($row)
                continue
            }
            $batchNumber++
            $rows.Add((New-BatchRow -Environment $group.Name -BatchNumber $batchNumber -Batch $batch))
            $batch = [System.Collections.Generic.List[object]]::new()
            $batch.Add($row)
        }
        if ($batch.Count -gt 0) {
            $batchNumber++
            $rows.Add((New-BatchRow -Environment $group.Name -BatchNumber $batchNumber -Batch $batch))
        }
    }
    return $rows.ToArray()
}

function New-BatchRow {
    param([string]$Environment, [int]$BatchNumber, [object[]]$Batch)
    [pscustomobject]@{
        Environment = $Environment
        BatchNumber = $BatchNumber
        StartTimeUtc = ([datetime]$Batch[0].StartTimeUtc).ToUniversalTime().ToString('o')
        ModelCount = @($Batch.SemanticModelId | Sort-Object -Unique).Count
        RefreshCount = $Batch.Count
    }
}

function Get-WeightedPercentile {
    param([object[]]$Rows, [string]$ValueProperty, [string]$WeightProperty, [double]$Percentile)
    $weightedRows = @($Rows | Where-Object { [double]$_.$WeightProperty -gt 0 } | Sort-Object { [double]$_.$ValueProperty })
    if ($weightedRows.Count -eq 0) { return 0 }
    $totalWeight = ($weightedRows | ForEach-Object { [double]$_.$WeightProperty } | Measure-Object -Sum).Sum
    $target = $totalWeight * ($Percentile / 100)
    $cumulative = 0.0
    foreach ($row in $weightedRows) {
        $cumulative += [double]$row.$WeightProperty
        if ($cumulative -ge $target) { return [double]$row.$ValueProperty }
    }
    return [double]$weightedRows[-1].$ValueProperty
}

function Get-EnvironmentWorkloadSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$RefreshRows,
        [Parameter(Mandatory)][object[]]$ConcurrencyRows,
        [double]$Percentile = 95
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $environments = @($RefreshRows.Environment | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($environment in $environments) {
        $refreshes = @($RefreshRows | Where-Object Environment -eq $environment)
        $concurrency = @($ConcurrencyRows | Where-Object Environment -eq $environment)
        $durations = @($refreshes | Where-Object { $_.DurationSeconds } | ForEach-Object { [double]$_.DurationSeconds })
        $counts = @($concurrency | ForEach-Object { [double]$_.ConcurrentRefreshes })
        $peakMemoryValues = @($refreshes | ForEach-Object { Get-OptionalProperty $_ 'PeakMemoryMB' } |
            Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [double]$_ })
        $rows.Add([pscustomobject]@{
            Environment = $environment
            RefreshCount = $refreshes.Count
            FailedRefreshCount = @($refreshes | Where-Object Status -eq 'Failed').Count
            PeakConcurrentRefreshes = if ($counts) { ($counts | Measure-Object -Maximum).Maximum } else { 0 }
            PercentileConcurrentRefreshes = [math]::Round((Get-WeightedPercentile -Rows $concurrency -ValueProperty 'ConcurrentRefreshes' -WeightProperty 'DurationSeconds' -Percentile $Percentile), 2)
            MedianDurationSeconds = [math]::Round((Get-Percentile -Values $durations -Percentile 50), 2)
            P95DurationSeconds = [math]::Round((Get-Percentile -Values $durations -Percentile 95), 2)
            MaximumObservedPeakMemoryMB = if ($peakMemoryValues) { ($peakMemoryValues | Measure-Object -Maximum).Maximum } else { $null }
        })
    }
    return $rows.ToArray()
}

Export-ModuleMember -Function Get-Percentile, Get-RefreshConcurrencySeries, Get-RefreshBatchSummary, Get-EnvironmentWorkloadSummary
