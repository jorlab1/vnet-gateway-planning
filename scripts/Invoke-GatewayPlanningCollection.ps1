[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [string]$CapacityEnvironmentMapPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Authentication.psm1') -Force
Import-Module (Join-Path $root 'src\PowerBIRest.psm1') -Force
Import-Module (Join-Path $root 'src\Inventory.psm1') -Force
Import-Module (Join-Path $root 'src\RefreshHistory.psm1') -Force

$configuration = Import-PowerShellDataFile -Path (Resolve-Path $ConfigurationPath)
$configurationDirectory = Split-Path -Parent (Resolve-Path $ConfigurationPath)
$historicalCollection = if ($configuration.HistoricalCollection) {
    $configuration.HistoricalCollection
} else {
    @{
        RefreshHistoryApi = @{ Enabled = $true; LookbackDays = 90; MaximumEntriesPerModel = 1000 }
        ActivityLog = @{ Enabled = $true; LookbackDays = 28 }
        ImportedRefreshHistoryPaths = @()
        ForwardObservation = @{ Enabled = $true; TargetDays = 90 }
    }
}
$outputPath = $configuration.OutputPath
if (-not [IO.Path]::IsPathRooted($outputPath)) { $outputPath = Join-Path $root $outputPath }
[void](New-Item -ItemType Directory -Force -Path $outputPath)

$classification = if ($configuration.CapacityEnvironmentClassification) {
    $configuration.CapacityEnvironmentClassification
} else {
    @{
        ExactMappings = @()
        MappingFile = ''
        Rules = @($configuration.CapacityEnvironmentRules)
        RequireAllCapacitiesClassified = $false
    }
}
$environmentRules = @($classification.Rules)
$explicitNameMap = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
$explicitIdMap = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
$validEnvironments = @('Dev', 'QA', 'UAT', 'Prod')

$mappingRows = [System.Collections.Generic.List[object]]::new()
foreach ($mapping in @($classification.ExactMappings)) { $mappingRows.Add([pscustomobject]$mapping) }

$configuredMapPath = if ($CapacityEnvironmentMapPath) {
    $CapacityEnvironmentMapPath
} elseif ($classification.MappingFile) {
    [string]$classification.MappingFile
} else { '' }
if ($configuredMapPath) {
    if (-not [IO.Path]::IsPathRooted($configuredMapPath)) {
        $configuredMapPath = Join-Path $configurationDirectory $configuredMapPath
    }
    if (-not (Test-Path $configuredMapPath)) {
        throw "Capacity environment mapping file not found: $configuredMapPath"
    }
    foreach ($row in @(Import-Csv $configuredMapPath)) { $mappingRows.Add($row) }
}

foreach ($row in $mappingRows) {
    $environment = [string]$row.Environment
    if ($environment -notin $validEnvironments) {
        throw "Invalid environment '$environment' in capacity mapping. Allowed values: $($validEnvironments -join ', ')."
    }
    $capacityId = [string]$row.CapacityId
    $capacityName = [string]$row.CapacityName
    if (-not $capacityId -and -not $capacityName) {
        throw 'Each capacity mapping must specify CapacityId or CapacityName.'
    }
    if ($capacityId) { $explicitIdMap[$capacityId.Trim()] = $environment }
    if ($capacityName) { $explicitNameMap[$capacityName.Trim()] = $environment }
}

foreach ($rule in $environmentRules) {
    if ([string]$rule.Environment -notin $validEnvironments) {
        throw "Invalid environment '$($rule.Environment)' in CapacityEnvironmentClassification.Rules."
    }
}

Connect-EstateIdentity -Configuration $configuration
$powerBiToken = Get-EstateAccessToken -Resource PowerBI
$fabricToken = Get-EstateAccessToken -Resource Fabric

$workspaces = @(Get-PowerBIAdminGroups -AccessToken $powerBiToken | Where-Object {
    $_.state -ne 'Deleted' -and $_.type -ne 'PersonalGroup'
})
if ($workspaces.Count -eq 0) { throw 'No tenant workspaces were returned. Verify Fabric administrator permissions and tenant settings.' }

$capacityObjects = @()
try {
    $capacityObjects = @(Get-PowerBIAdminCapacities -AccessToken $powerBiToken)
} catch {
    Write-Warning "Power BI Admin capacities were unavailable; trying Fabric capacities. $($_.Exception.Message)"
    $capacityObjects = @(Get-FabricCapacities -AccessToken $fabricToken)
}

$capacityLookup = @{}
$capacityRows = foreach ($capacity in $capacityObjects) {
    $id = [string]$capacity.id
    $name = if ($capacity.displayName) { $capacity.displayName } else { $capacity.name }
    $sku = if ($capacity.sku) { [string]$capacity.sku } else { [string]$capacity.skuName }
    $environment = Resolve-EstateEnvironment -CapacityName $name -CapacityId $id -Rules $environmentRules `
        -ExplicitNameMap $explicitNameMap -ExplicitIdMap $explicitIdMap
    $normalized = [pscustomobject]@{
        CapacityId = $id
        CapacityName = $name
        DisplayName = $name
        Environment = $environment
        Sku = $sku
        Region = $capacity.region
        State = $capacity.state
    }
    $capacityLookup[$id] = $normalized
    $normalized
}

$scanResults = Invoke-PowerBIEstateScan -Workspaces $workspaces -AccessToken $powerBiToken -ScannerConfiguration $configuration.Scanner
$inventory = ConvertTo-EstateInventory -ScanResults $scanResults -CapacityLookup $capacityLookup `
    -EnvironmentRules $environmentRules -ExplicitEnvironmentNameMap $explicitNameMap `
    -ExplicitEnvironmentIdMap $explicitIdMap

$unclassifiedCapacities = @($capacityRows | Where-Object Environment -eq 'Unclassified')
if ($classification.RequireAllCapacitiesClassified -and $unclassifiedCapacities.Count -gt 0) {
    $names = $unclassifiedCapacities.CapacityName -join ', '
    throw "Unclassified capacities remain and RequireAllCapacitiesClassified is enabled: $names"
}

$refreshResult = if ($historicalCollection.RefreshHistoryApi.Enabled) {
    Get-SemanticModelRefreshHistory -SemanticModels $inventory.SemanticModels -AccessToken $powerBiToken `
        -Top $historicalCollection.RefreshHistoryApi.MaximumEntriesPerModel `
        -LookbackDays $historicalCollection.RefreshHistoryApi.LookbackDays
} else {
    @{ Rows = @(); Exceptions = @() }
}

$importPaths = @($historicalCollection.ImportedRefreshHistoryPaths | ForEach-Object {
    $path = [string]$_
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $configurationDirectory $path }
    $path
})
$importedRefreshRows = if ($importPaths.Count -gt 0) {
    @(Import-RetainedRefreshHistory -Paths $importPaths)
} else { @() }
$allRefreshRows = @($refreshResult.Rows) + $importedRefreshRows
$allRefreshRows = @($allRefreshRows | Group-Object {
    if ($_.RequestId) {
        "$($_.WorkspaceId)|$($_.SemanticModelId)|$($_.RequestId)"
    } else {
        "$($_.WorkspaceId)|$($_.SemanticModelId)|$($_.StartTimeUtc)|$($_.RefreshType)"
    }
} | ForEach-Object { $_.Group[0] })

$activityRows = @()
if ($historicalCollection.ActivityLog.Enabled) {
    $end = [datetime]::UtcNow
    $start = $end.AddDays(-[math]::Min(28, [int]$historicalCollection.ActivityLog.LookbackDays))
    try {
        $activityRows = @(Get-PowerBIActivityEvents -AccessToken $powerBiToken -StartDateUtc $start -EndDateUtc $end)
    } catch {
        Write-Warning "Activity-log collection failed; inventory and refresh history will still be exported. $($_.Exception.Message)"
    }
}

$policyExceptions = @($inventory.SemanticModels | Where-Object {
    $_.Environment -in 'Dev', 'QA' -and "$($_.RefreshScheduleEnabled)" -eq 'True'
} | ForEach-Object {
    [pscustomobject]@{
        Type = 'ScheduledRefreshPolicy'
        WorkspaceId = $_.WorkspaceId
        SemanticModelId = $_.SemanticModelId
        Detail = "Enabled refresh schedule detected in $($_.Environment)."
    }
})
$policyExceptions += foreach ($refresh in $allRefreshRows) {
    if ($refresh.Environment -in 'Dev', 'QA' -and $refresh.RefreshType -eq 'Scheduled') {
        [pscustomobject]@{
            Type = 'ScheduledRefreshPolicy'
            WorkspaceId = $refresh.WorkspaceId
            SemanticModelId = $refresh.SemanticModelId
            Detail = "Scheduled refresh detected in $($refresh.Environment) at $($refresh.StartTimeUtc)."
        }
    }
}
$exceptions = @($inventory.Exceptions) + @($refreshResult.Exceptions) + @($policyExceptions)

$exports = [ordered]@{
    'capacity-inventory.csv' = @($capacityRows)
    'workspaces.csv' = @($inventory.Workspaces)
    'semantic-models.csv' = @($inventory.SemanticModels)
    'model-data-sources.csv' = @($inventory.DataSources)
    'refresh-history.csv' = @($allRefreshRows)
    'activity-events.csv' = @($activityRows)
    'policy-exceptions.csv' = @($policyExceptions)
    'data-quality-exceptions.csv' = @($exceptions)
}
foreach ($name in $exports.Keys) {
    $path = Join-Path $outputPath $name
    $exports[$name] | Export-Csv -Path $path -NoTypeInformation -Encoding utf8
}

$manifest = [ordered]@{
    CollectedAtUtc = [datetime]::UtcNow.ToString('o')
    AuthenticationMode = $configuration.Authentication.Mode
    WorkspaceCount = @($inventory.Workspaces).Count
    SemanticModelCount = @($inventory.SemanticModels).Count
    RefreshHistoryCount = @($allRefreshRows).Count
    ApiRefreshHistoryCount = @($refreshResult.Rows).Count
    ImportedRefreshHistoryCount = @($importedRefreshRows).Count
    EarliestRefreshStartUtc = @($allRefreshRows.StartTimeUtc | Where-Object { $_ } | Sort-Object | Select-Object -First 1)[0]
    LatestRefreshStartUtc = @($allRefreshRows.StartTimeUtc | Where-Object { $_ } | Sort-Object | Select-Object -Last 1)[0]
    ActivityEventCount = @($activityRows).Count
    ExceptionCount = @($exceptions).Count
    RefreshHistoryLookbackDaysRequested = $historicalCollection.RefreshHistoryApi.LookbackDays
    RefreshHistoryMaximumEntriesPerModel = $historicalCollection.RefreshHistoryApi.MaximumEntriesPerModel
    ActivityHistoryDaysRequested = [math]::Min(28, [int]$historicalCollection.ActivityLog.LookbackDays)
    ForwardObservationEnabled = $historicalCollection.ForwardObservation.Enabled
    ObservationTargetDays = $historicalCollection.ForwardObservation.TargetDays
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outputPath 'collection-manifest.json') -Encoding utf8

Write-Host "Inventory complete: $outputPath"
