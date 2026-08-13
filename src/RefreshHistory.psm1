Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalProperty {
    param([object]$InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-ExecutionMetric {
    param([object[]]$Attempts, [string[]]$Names, [ValidateSet('Maximum', 'Sum')][string]$Aggregate)
    $values = [System.Collections.Generic.List[double]]::new()
    foreach ($attempt in $Attempts) {
        foreach ($metrics in @(Get-OptionalProperty $attempt 'executionMetrics' @())) {
            foreach ($name in $Names) {
                $value = Get-OptionalProperty $metrics $name
                if ($null -ne $value -and "$value" -ne '') {
                    $parsed = 0.0
                    if ([double]::TryParse([string]$value, [ref]$parsed)) { $values.Add($parsed) }
                }
            }
        }
    }
    if ($values.Count -eq 0) { return $null }
    if ($Aggregate -eq 'Sum') { return ($values | Measure-Object -Sum).Sum }
    return ($values | Measure-Object -Maximum).Maximum
}

function Get-SemanticModelRefreshHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$SemanticModels,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$Top = 1000,
        [int]$LookbackDays = 0
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $exceptions = [System.Collections.Generic.List[object]]::new()
    $cutoff = if ($LookbackDays -gt 0) { [datetime]::UtcNow.AddDays(-$LookbackDays) } else { $null }
    foreach ($model in $SemanticModels) {
        $uri = "https://api.powerbi.com/v1.0/myorg/groups/$($model.WorkspaceId)/datasets/$($model.SemanticModelId)/refreshes?`$top=$Top"
        try {
            $response = Invoke-EstateRestMethod -Uri $uri -AccessToken $AccessToken
            foreach ($refresh in @(Get-OptionalProperty $response 'value' @())) {
                $startTime = Get-OptionalProperty $refresh 'startTime' ''
                $endTime = Get-OptionalProperty $refresh 'endTime' ''
                $attempts = @(Get-OptionalProperty $refresh 'refreshAttempts' @())
                $start = if ($startTime) { [datetime]::Parse($startTime).ToUniversalTime() } else { $null }
                $end = if ($endTime) { [datetime]::Parse($endTime).ToUniversalTime() } else { $null }
                if ($cutoff -and $start -and $start -lt $cutoff) { continue }
                $metricsJson = if ($attempts.Count -gt 0) {
                    @($attempts | ForEach-Object { Get-OptionalProperty $_ 'executionMetrics' @() }) | ConvertTo-Json -Depth 10 -Compress
                } else { '' }
                $peakMemoryKb = Get-ExecutionMetric -Attempts $attempts -Names @(
                    'approximatePeakMemConsumptionKB', 'peakMemoryKB', 'peakMemoryKb'
                ) -Aggregate Maximum
                $mEngineCpuMs = Get-ExecutionMetric -Attempts $attempts -Names @(
                    'mEngineCpuTimeMs', 'mEngineCpuTime'
                ) -Aggregate Sum
                $totalCpuMs = Get-ExecutionMetric -Attempts $attempts -Names @(
                    'totalCpuTimeMs', 'cpuTimeMs'
                ) -Aggregate Sum
                $rows.Add([pscustomobject]@{
                    WorkspaceId = $model.WorkspaceId
                    WorkspaceName = $model.WorkspaceName
                    CapacityId = $model.CapacityId
                    CapacityName = $model.CapacityName
                    Environment = $model.Environment
                    SemanticModelId = $model.SemanticModelId
                    SemanticModelName = $model.SemanticModelName
                    RequestId = Get-OptionalProperty $refresh 'requestId' ''
                    RefreshType = Get-OptionalProperty $refresh 'refreshType' ''
                    Status = Get-OptionalProperty $refresh 'status' ''
                    StartTimeUtc = $start
                    EndTimeUtc = $end
                    DurationSeconds = if ($start -and $end) { [math]::Round(($end - $start).TotalSeconds, 2) } else { $null }
                    AttemptCount = $attempts.Count
                    Error = Get-OptionalProperty $refresh 'serviceExceptionJson' ''
                    PeakMemoryMB = if ($null -ne $peakMemoryKb) { [math]::Round($peakMemoryKb / 1024, 2) } else { $null }
                    MEngineCpuTimeMs = $mEngineCpuMs
                    TotalCpuTimeMs = $totalCpuMs
                    ExecutionMetricsJson = $metricsJson
                    HistorySource = 'PowerBIRefreshHistoryApi'
                })
            }
        }
        catch {
            $exceptions.Add([pscustomobject]@{
                Type = 'RefreshHistory'
                WorkspaceId = $model.WorkspaceId
                SemanticModelId = $model.SemanticModelId
                Detail = $_.Exception.Message
            })
        }
    }
    return @{ Rows = $rows.ToArray(); Exceptions = $exceptions.ToArray() }
}

function Import-RetainedRefreshHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Paths)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) { throw "Retained refresh history file not found: $path" }
        foreach ($row in @(Import-Csv $path)) {
            if (-not $row.WorkspaceId -or -not $row.SemanticModelId -or -not $row.StartTimeUtc) {
                throw "Retained refresh history must contain WorkspaceId, SemanticModelId, and StartTimeUtc: $path"
            }
            $normalized = [ordered]@{}
            foreach ($property in $row.PSObject.Properties) { $normalized[$property.Name] = $property.Value }
            $normalized['HistorySource'] = if ($row.PSObject.Properties['HistorySource'] -and $row.HistorySource) {
                $row.HistorySource
            } else { "Imported:$([IO.Path]::GetFileName($path))" }
            $rows.Add([pscustomobject]$normalized)
        }
    }
    return $rows.ToArray()
}

function Get-PowerBIActivityEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][datetime]$StartDateUtc,
        [Parameter(Mandatory)][datetime]$EndDateUtc
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    for ($day = $StartDateUtc.Date; $day -le $EndDateUtc.Date; $day = $day.AddDays(1)) {
        $sliceStart = if ($day -lt $StartDateUtc) { $StartDateUtc } else { $day }
        $sliceEndCandidate = $day.AddDays(1).AddMilliseconds(-1)
        $sliceEnd = if ($sliceEndCandidate -gt $EndDateUtc) { $EndDateUtc } else { $sliceEndCandidate }
        $startText = $sliceStart.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $endText = $sliceEnd.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $uri = "https://api.powerbi.com/v1.0/myorg/admin/activityevents?startDateTime='$startText'&endDateTime='$endText'"
        do {
            $response = Invoke-EstateRestMethod -Uri $uri -AccessToken $AccessToken
            foreach ($event in @(Get-OptionalProperty $response 'activityEventEntities' @())) {
                $rows.Add([pscustomobject]@{
                    Id = Get-OptionalProperty $event 'Id' ''
                    CreationTimeUtc = Get-OptionalProperty $event 'CreationTime' ''
                    Activity = Get-OptionalProperty $event 'Activity' ''
                    Operation = Get-OptionalProperty $event 'Operation' ''
                    UserId = Get-OptionalProperty $event 'UserId' ''
                    WorkspaceId = Get-OptionalProperty $event 'WorkspaceId' ''
                    WorkspaceName = Get-OptionalProperty $event 'WorkSpaceName' ''
                    ArtifactId = Get-OptionalProperty $event 'ArtifactId' ''
                    ArtifactName = Get-OptionalProperty $event 'ArtifactName' ''
                    DatasetId = Get-OptionalProperty $event 'DatasetId' ''
                    DatasetName = Get-OptionalProperty $event 'DatasetName' ''
                    RequestId = Get-OptionalProperty $event 'RequestId' ''
                })
            }
            $uri = Get-OptionalProperty $response 'continuationUri'
        } while ($uri)
    }
    return $rows.ToArray()
}

function Merge-EstateCsvRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$NewRows,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$KeyColumns
    )

    $allRows = [System.Collections.Generic.List[object]]::new()
    if (Test-Path $Path) {
        foreach ($row in @(Import-Csv $Path)) { $allRows.Add($row) }
    }
    foreach ($row in $NewRows) { $allRows.Add($row) }

    $deduplicated = $allRows | Group-Object {
        $row = $_
        ($KeyColumns | ForEach-Object { [string]$row.$_ }) -join '|'
    } | ForEach-Object { $_.Group[-1] }
    $deduplicated | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
    return @($deduplicated).Count
}

Export-ModuleMember -Function Get-SemanticModelRefreshHistory, Get-PowerBIActivityEvents, Import-RetainedRefreshHistory, Merge-EstateCsvRows
