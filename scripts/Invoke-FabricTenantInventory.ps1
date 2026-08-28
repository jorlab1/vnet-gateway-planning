<#
    .SYNOPSIS
    Inventories Power BI/Fabric capacities, workspaces, and semantic models into one CSV.

    .DESCRIPTION
    Runs read-only Power BI admin APIs and writes a single CSV with these columns:

        CapacityName,CapacityId,WorkspaceName,WorkspaceId,SemanticModelName,SemanticModelCreatedAt,TargetStorageMode

    Three authentication modes are supported:

        ServicePrincipal  Client credentials. Unattended; the default.
        DeviceCode        Interactive sign-in as a Fabric administrator. No secret.
        AzureCli          Reuses an existing 'az login'. No secret.

    Settings resolve from parameters, then process environment variables, then an
    optional .env file. The client secret additionally falls back to the Windows
    user-scoped environment variable, so no .env file is required.

    .EXAMPLE
    pwsh .\scripts\Invoke-FabricTenantInventory.ps1

    .EXAMPLE
    pwsh .\scripts\Invoke-FabricTenantInventory.ps1 -AuthMode AzureCli

    .EXAMPLE
    pwsh .\scripts\Invoke-FabricTenantInventory.ps1 -AuthMode DeviceCode `
        -TenantId 00000000-0000-0000-0000-000000000000

    .EXAMPLE
    pwsh .\scripts\Invoke-FabricTenantInventory.ps1 `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -ClientId 11111111-1111-1111-1111-111111111111 `
        -ClientSecretEnvironmentVariable FABRIC_TEST_SP_SECRET
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'ServicePrincipal', 'DeviceCode', 'AzureCli')][string]$AuthMode = '',
    [string]$TenantId = '',
    [string]$ClientId = '',
    [string]$ClientSecretEnvironmentVariable = '',
    [string]$EnvironmentFilePath = '',
    [string]$OutputPath = '',
    [int]$WorkspaceBatchSize = 100,
    [int]$PollSeconds = 2,
    [int]$SignInTimeoutSeconds = 300,
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

$credential = Get-InventoryCredential -AuthMode $AuthMode -TenantId $TenantId -ClientId $ClientId `
    -ClientSecretEnvironmentVariable $ClientSecretEnvironmentVariable -EnvironmentFilePath $EnvironmentFilePath

Write-Host "Auth mode $($credential.AuthMode) (from $($credential.AuthModeSource))"
if ($credential.TenantId) { Write-Host "Tenant $($credential.TenantId) (from $($credential.TenantIdSource))" }
if ($credential.ClientId) { Write-Host "Client $($credential.ClientId) (from $($credential.ClientIdSource))" }
if ($credential.AuthMode -eq 'ServicePrincipal') {
    Write-Host "Secret variable $($credential.ClientSecretVariableName) (from $($credential.ClientSecretSource))"
}

$token = Get-InventoryToken -AuthMode $credential.AuthMode -TenantId $credential.TenantId `
    -ClientId $credential.ClientId -ClientSecret $credential.ClientSecret -TimeoutSeconds $SignInTimeoutSeconds

# Preflight: capacities is the cheapest admin call and fails fast when the
# caller is not authorized for tenant-wide read-only admin APIs.
try {
    $capacities = @(Get-InventoryCapacity -AccessToken $token)
}
catch {
    if ($credential.AuthMode -eq 'ServicePrincipal') {
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

    throw @"
Tenant admin access check failed.

$($_.Exception.Message)

The signed-in user must hold the Fabric Administrator (or Power BI Administrator)
role. Workspace-level Member or Admin access is not sufficient. If sign-in itself
succeeded, confirm the role assignment and that the token was issued for the
correct tenant.
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
    throw 'No active workspaces were returned. Verify the caller is authorized for the read-only admin APIs.'
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
