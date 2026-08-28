<#
    .SYNOPSIS
    Inventories Power BI/Fabric capacities, workspaces, and semantic models into one CSV.

    .DESCRIPTION
    Runs read-only Power BI admin APIs as a service principal and writes a single
    CSV with these columns:

        CapacityName,CapacityId,WorkspaceName,WorkspaceId,SemanticModelName,SemanticModelCreatedAt,TargetStorageMode

    Credentials resolve from parameters, then process environment variables, then
    an optional .env file. The client secret additionally falls back to the Windows
    user-scoped environment variable, so no .env file is required.

    .EXAMPLE
    pwsh .\scripts\Invoke-FabricTenantInventory.ps1

    .EXAMPLE
    pwsh .\scripts\Invoke-FabricTenantInventory.ps1 `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -ClientId 11111111-1111-1111-1111-111111111111 `
        -ClientSecretEnvironmentVariable FABRIC_TEST_SP_SECRET
#>
[CmdletBinding()]
param(
    [string]$TenantId = '',
    [string]$ClientId = '',
    [string]$ClientSecretEnvironmentVariable = '',
    [string]$EnvironmentFilePath = '',
    [string]$OutputPath = '',
    [int]$WorkspaceBatchSize = 100,
    [int]$PollSeconds = 2,
    [switch]$TestConnectionOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\InventoryConfiguration.psm1') -Force
Import-Module (Join-Path $root 'src\InventoryAuthentication.psm1') -Force
Import-Module (Join-Path $root 'src\PowerBIAdminApi.psm1') -Force
Import-Module (Join-Path $root 'src\TenantInventory.psm1') -Force

if (-not $EnvironmentFilePath) { $EnvironmentFilePath = Join-Path $root '.env' }
if (-not $OutputPath) { $OutputPath = Join-Path $root 'output\powerbi-inventory.csv' }
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $root $OutputPath }

$started = [datetime]::UtcNow

$credential = Get-InventoryCredential -TenantId $TenantId -ClientId $ClientId `
    -ClientSecretEnvironmentVariable $ClientSecretEnvironmentVariable -EnvironmentFilePath $EnvironmentFilePath

Write-Host "Tenant $($credential.TenantId) (from $($credential.TenantIdSource))"
Write-Host "Client $($credential.ClientId) (from $($credential.ClientIdSource))"
Write-Host "Secret variable $($credential.ClientSecretVariableName) (from $($credential.ClientSecretSource))"

$token = Get-InventoryAccessToken -TenantId $credential.TenantId -ClientId $credential.ClientId -ClientSecret $credential.ClientSecret

# Preflight: capacities is the cheapest admin call and fails fast when the
# service principal is not authorized for tenant-wide read-only admin APIs.
try {
    $capacities = @(Get-InventoryCapacity -AccessToken $token)
}
catch {
    throw @"
Tenant admin access check failed.

$($_.Exception.Message)

Workspace-level Member or Admin access is not sufficient. The service principal must be:
  1. A member of a security group listed in the Fabric admin portal setting
     'Service principals can access read-only admin APIs'.
  2. Covered by 'Enhanced admin APIs for workspace and content scanning' for the
     workspace scanner endpoints.
  3. Free of admin-consent-required Power BI application permissions.
"@
}

Write-Host "Capacities: $($capacities.Count)"
if ($TestConnectionOnly) {
    Write-Host 'Connection test succeeded.'
    return
}

$workspaces = @(Get-InventoryWorkspace -AccessToken $token)
Write-Host "Active non-personal workspaces: $($workspaces.Count)"
if ($workspaces.Count -eq 0) {
    throw 'No active workspaces were returned. Verify the service principal is allowed to call the read-only admin APIs.'
}

$scanResults = @(Invoke-InventoryWorkspaceScan -Workspaces $workspaces -AccessToken $token `
        -BatchSize $WorkspaceBatchSize -PollSeconds $PollSeconds)

$inventory = ConvertTo-TenantInventory -ScanResults $scanResults -Capacities $capacities

foreach ($capacityId in $inventory.UnknownCapacityIds) {
    Write-Warning "Workspaces reference capacity $capacityId, which was not returned by the capacities endpoint. CapacityName is blank for those rows."
}
if ($inventory.SkippedWorkspaces.Count -gt 0) {
    Write-Warning "Excluded $($inventory.SkippedWorkspaces.Count) workspace(s) with no capacity assignment."
}
if ($inventory.ModelsMissingCreatedDate -gt 0) {
    Write-Warning "$($inventory.ModelsMissingCreatedDate) semantic model(s) have no usable creation timestamp; SemanticModelCreatedAt is blank for those rows."
}

$rowCount = Export-TenantInventoryCsv -Rows $inventory.Rows -Path $OutputPath

Write-Host ''
Write-Host "Semantic models written: $rowCount"
Write-Host "Duplicate names resolved to newest: $($inventory.DuplicateModelsResolved)"
Write-Host "Elapsed: $([math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 1))s"
Write-Host "Inventory written to $OutputPath"
