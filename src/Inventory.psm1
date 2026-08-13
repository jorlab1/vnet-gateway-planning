Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalProperty {
    param([object]$InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Resolve-EstateEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CapacityName,
        [AllowEmptyString()][string]$CapacityId = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [hashtable]$ExplicitNameMap,
        [hashtable]$ExplicitIdMap
    )

    if ($CapacityId -and $ExplicitIdMap -and $ExplicitIdMap.ContainsKey($CapacityId)) {
        return $ExplicitIdMap[$CapacityId]
    }
    if ($ExplicitNameMap -and $ExplicitNameMap.ContainsKey($CapacityName)) {
        return $ExplicitNameMap[$CapacityName]
    }

    $matches = @($Rules | Where-Object { $CapacityName -match $_.Pattern })
    if ($matches.Count -eq 1) { return $matches[0].Environment }
    return 'Unclassified'
}

function Start-WorkspaceScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$WorkspaceIds,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][hashtable]$ScannerConfiguration
    )

    $query = @(
        "lineage=$($ScannerConfiguration.IncludeLineage.ToString().ToLowerInvariant())"
        "datasourceDetails=$($ScannerConfiguration.IncludeDatasourceDetails.ToString().ToLowerInvariant())"
        "datasetSchema=$($ScannerConfiguration.IncludeDatasetSchema.ToString().ToLowerInvariant())"
        "datasetExpressions=$($ScannerConfiguration.IncludeDatasetExpressions.ToString().ToLowerInvariant())"
    ) -join '&'
    $uri = "https://api.powerbi.com/v1.0/myorg/admin/workspaces/getInfo?$query"
    $response = Invoke-EstateRestMethod -Uri $uri -AccessToken $AccessToken -Method POST -Body @{ workspaces = $WorkspaceIds }
    return $response.id
}

function Wait-WorkspaceScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScanId,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$PollSeconds = 2,
        [int]$MaximumPolls = 300
    )

    $statusUri = "https://api.powerbi.com/v1.0/myorg/admin/workspaces/scanStatus/$ScanId"
    $poll = 0
    do {
        $poll++
        $status = Invoke-EstateRestMethod -Uri $statusUri -AccessToken $AccessToken
        if ($status.status -eq 'Failed') { throw "Workspace scan $ScanId failed." }
        if ($status.status -ne 'Succeeded') { Start-Sleep -Seconds $PollSeconds }
        if ($poll -ge $MaximumPolls -and $status.status -ne 'Succeeded') {
            throw "Workspace scan $ScanId did not complete after $MaximumPolls polls."
        }
    } while ($status.status -ne 'Succeeded')

    return Invoke-EstateRestMethod -Uri "https://api.powerbi.com/v1.0/myorg/admin/workspaces/scanResult/$ScanId" -AccessToken $AccessToken
}

function Invoke-PowerBIEstateScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Workspaces,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][hashtable]$ScannerConfiguration
    )

    $batchSize = [Math]::Min(100, [int]$ScannerConfiguration.WorkspaceBatchSize)
    $scanResults = [System.Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Workspaces.Count; $offset += $batchSize) {
        $last = [Math]::Min($offset + $batchSize - 1, $Workspaces.Count - 1)
        $ids = @($Workspaces[$offset..$last] | ForEach-Object { [string]$_.id })
        $scanId = Start-WorkspaceScan -WorkspaceIds $ids -AccessToken $AccessToken -ScannerConfiguration $ScannerConfiguration
        $scanResults.Add((Wait-WorkspaceScan -ScanId $scanId -AccessToken $AccessToken -PollSeconds $ScannerConfiguration.PollSeconds))
    }
    return $scanResults.ToArray()
}

function ConvertTo-EstateInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$ScanResults,
        [Parameter(Mandatory)][hashtable]$CapacityLookup,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EnvironmentRules,
        [hashtable]$ExplicitEnvironmentNameMap,
        [hashtable]$ExplicitEnvironmentIdMap
    )

    $workspaceRows = [System.Collections.Generic.List[object]]::new()
    $modelRows = [System.Collections.Generic.List[object]]::new()
    $sourceRows = [System.Collections.Generic.List[object]]::new()
    $exceptions = [System.Collections.Generic.List[object]]::new()

    foreach ($scan in $ScanResults) {
        foreach ($workspace in @($scan.workspaces)) {
            $workspaceId = [string](Get-OptionalProperty $workspace 'id' '')
            $capacityId = [string](Get-OptionalProperty $workspace 'capacityId' '')
            $capacityName = if ($capacityId -and $CapacityLookup.ContainsKey($capacityId)) {
                $CapacityLookup[$capacityId].DisplayName
            } else { '' }
            $environment = Resolve-EstateEnvironment -CapacityName $capacityName -CapacityId $capacityId `
                -Rules $EnvironmentRules -ExplicitNameMap $ExplicitEnvironmentNameMap `
                -ExplicitIdMap $ExplicitEnvironmentIdMap
            $workspaceRows.Add([pscustomobject]@{
                WorkspaceId = $workspaceId
                WorkspaceName = Get-OptionalProperty $workspace 'name' ''
                WorkspaceState = Get-OptionalProperty $workspace 'state' ''
                CapacityId = $capacityId
                CapacityName = $capacityName
                Environment = $environment
            })
            if ($environment -eq 'Unclassified') {
                $exceptions.Add([pscustomobject]@{
                    Type = 'EnvironmentClassification'
                    WorkspaceId = $workspaceId
                    SemanticModelId = ''
                    Detail = "Capacity '$capacityName' did not match exactly one environment rule."
                })
            }

            $datasourceInstances = @{}
            foreach ($instance in @(Get-OptionalProperty $workspace 'datasourceInstances' @())) {
                $datasourceId = [string](Get-OptionalProperty $instance 'datasourceId' '')
                if ($datasourceId) { $datasourceInstances[$datasourceId] = $instance }
            }

            foreach ($dataset in @(Get-OptionalProperty $workspace 'datasets' @())) {
                $tables = @(Get-OptionalProperty $dataset 'tables' @())
                $datasourceUsages = @(Get-OptionalProperty $dataset 'datasourceUsages' @())
                $targetStorageMode = Get-OptionalProperty $dataset 'targetStorageMode' ''
                $refreshSchedule = Get-OptionalProperty $dataset 'refreshSchedule'
                $tableModes = @($tables | ForEach-Object { Get-OptionalProperty $_ 'storageMode' '' } | Where-Object { $_ } | Sort-Object -Unique)
                $storageMode = if ($targetStorageMode) {
                    $targetStorageMode
                } elseif ($tableModes.Count -eq 1) {
                    $tableModes[0]
                } elseif ($tableModes.Count -gt 1) {
                    'Mixed'
                } else {
                    'Unknown'
                }
                $modelRows.Add([pscustomobject]@{
                    WorkspaceId = $workspaceId
                    WorkspaceName = Get-OptionalProperty $workspace 'name' ''
                    CapacityId = $capacityId
                    CapacityName = $capacityName
                    Environment = $environment
                    SemanticModelId = Get-OptionalProperty $dataset 'id' ''
                    SemanticModelName = Get-OptionalProperty $dataset 'name' ''
                    ConfiguredBy = Get-OptionalProperty $dataset 'configuredBy' ''
                    CreatedDate = Get-OptionalProperty $dataset 'createdDate' ''
                    ModifiedDate = Get-OptionalProperty $dataset 'modifiedDate' ''
                    Refreshable = Get-OptionalProperty $dataset 'isRefreshable' ''
                    TargetStorageMode = $targetStorageMode
                    StorageMode = $storageMode
                    TableCount = $tables.Count
                    DatasourceCount = $datasourceUsages.Count
                    Endorsement = Get-OptionalProperty (Get-OptionalProperty $dataset 'endorsementDetails') 'endorsement' ''
                    RefreshScheduleEnabled = Get-OptionalProperty $refreshSchedule 'enabled' ''
                    RefreshScheduleDays = @((Get-OptionalProperty $refreshSchedule 'days' @())) -join ';'
                    RefreshScheduleTimes = @((Get-OptionalProperty $refreshSchedule 'times' @())) -join ';'
                    EstimatedModelSizeMB = Get-OptionalProperty $dataset 'sizeInMB' (Get-OptionalProperty $dataset 'modelSizeInMB' '')
                })

                foreach ($usage in $datasourceUsages) {
                    $instanceId = [string](Get-OptionalProperty $usage 'datasourceInstanceId' '')
                    $instance = if ($datasourceInstances.ContainsKey($instanceId)) { $datasourceInstances[$instanceId] } else { $null }
                    $connection = Get-OptionalProperty $instance 'connectionDetails'
                    $url = Get-OptionalProperty $connection 'url' ''
                    $parsedUrl = $null
                    $urlHost = if ($url -and [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsedUrl)) { $parsedUrl.Host } else { '' }
                    $sourceRows.Add([pscustomobject]@{
                        WorkspaceId = $workspaceId
                        SemanticModelId = Get-OptionalProperty $dataset 'id' ''
                        SemanticModelName = Get-OptionalProperty $dataset 'name' ''
                        Environment = $environment
                        DatasourceInstanceId = $instanceId
                        DatasourceType = Get-OptionalProperty $instance 'datasourceType' ''
                        GatewayId = Get-OptionalProperty $instance 'gatewayId' (Get-OptionalProperty $usage 'gatewayId' '')
                        Server = Get-OptionalProperty $connection 'server' ''
                        Database = Get-OptionalProperty $connection 'database' ''
                        UrlHost = $urlHost
                    })
                }
            }
        }
    }

    return @{
        Workspaces = $workspaceRows.ToArray()
        SemanticModels = $modelRows.ToArray()
        DataSources = $sourceRows.ToArray()
        Exceptions = $exceptions.ToArray()
    }
}

Export-ModuleMember -Function Resolve-EstateEnvironment, Invoke-PowerBIEstateScan, ConvertTo-EstateInventory
