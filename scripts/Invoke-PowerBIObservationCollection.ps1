[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [int]$LookbackDays = 2
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Authentication.psm1') -Force
Import-Module (Join-Path $root 'src\PowerBIRest.psm1') -Force
Import-Module (Join-Path $root 'src\RefreshHistory.psm1') -Force

$configuration = Import-PowerShellDataFile -Path (Resolve-Path $ConfigurationPath)
$historicalCollection = if ($configuration.HistoricalCollection) {
    $configuration.HistoricalCollection
} else {
    @{
        RefreshHistoryApi = @{ Enabled = $true; LookbackDays = 90; MaximumEntriesPerModel = 1000 }
        ActivityLog = @{ Enabled = $true; LookbackDays = 28 }
        ForwardObservation = @{ Enabled = $true; TargetDays = 90 }
    }
}
$outputPath = $configuration.OutputPath
if (-not [IO.Path]::IsPathRooted($outputPath)) { $outputPath = Join-Path $root $outputPath }
$modelPath = Join-Path $outputPath 'semantic-models.csv'
if (-not (Test-Path $modelPath)) { throw "Run Invoke-PowerBIEstateInventory.ps1 first; missing $modelPath." }

Connect-EstateIdentity -Configuration $configuration
$token = Get-EstateAccessToken -Resource PowerBI
$models = @(Import-Csv $modelPath)
$refreshResult = Get-SemanticModelRefreshHistory -SemanticModels $models -AccessToken $token `
    -Top $historicalCollection.RefreshHistoryApi.MaximumEntriesPerModel `
    -LookbackDays $historicalCollection.RefreshHistoryApi.LookbackDays
$refreshCount = Merge-EstateCsvRows -NewRows $refreshResult.Rows -Path (Join-Path $outputPath 'refresh-history.csv') -KeyColumns @('WorkspaceId', 'SemanticModelId', 'RequestId')

$activityCount = 0
if ($historicalCollection.ActivityLog.Enabled) {
    $end = [datetime]::UtcNow
    $events = @(Get-PowerBIActivityEvents -AccessToken $token -StartDateUtc $end.AddDays(-$LookbackDays) -EndDateUtc $end)
    $activityCount = Merge-EstateCsvRows -NewRows $events -Path (Join-Path $outputPath 'activity-events.csv') -KeyColumns @('Id')
}

[pscustomobject]@{
    CollectedAtUtc = [datetime]::UtcNow.ToString('o')
    RefreshRowsRetained = $refreshCount
    ActivityRowsRetained = $activityCount
    RefreshCollectionErrors = @($refreshResult.Exceptions).Count
} | Export-Csv -Path (Join-Path $outputPath 'observation-run.csv') -Append -NoTypeInformation -Encoding utf8

Write-Host "Observation collection complete: $outputPath"
