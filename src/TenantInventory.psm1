Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The exported contract. Column order is part of the contract and is asserted by tests.
$script:InventoryColumns = @(
    'CapacityName'
    'CapacityId'
    'WorkspaceName'
    'WorkspaceId'
    'SemanticModelName'
    'SemanticModelCreatedAt'
    'TargetStorageMode'
)

function Get-InventoryProperty {
    param([object]$InputObject, [string]$Name, $Default = $null)

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-InventoryColumnName {
    [CmdletBinding()]
    param()
    return $script:InventoryColumns
}

function ConvertTo-InventoryTimestamp {
    <#
        .SYNOPSIS
        Parses an API creation timestamp into a UTC DateTimeOffset.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if (-not $Value) { return $null }
    $parsed = [datetimeoffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetimeoffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function ConvertTo-TenantInventory {
    <#
        .SYNOPSIS
        Flattens workspace scan results into capacity/workspace/semantic-model rows.

        .DESCRIPTION
        Workspaces without a capacity assignment are excluded and reported.
        Semantic models with the same name inside one workspace are collapsed to
        the most recently created model, compared as parsed UTC timestamps.
        Identical names in different workspaces are preserved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ScanResults,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Capacities
    )

    $capacityLookup = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($capacity in $Capacities) {
        $capacityId = [string](Get-InventoryProperty $capacity 'id' '')
        if (-not $capacityId) { continue }
        $displayName = [string](Get-InventoryProperty $capacity 'displayName' (Get-InventoryProperty $capacity 'name' ''))
        $capacityLookup[$capacityId] = [pscustomobject]@{
            CapacityId = $capacityId
            CapacityName = $displayName
            State = [string](Get-InventoryProperty $capacity 'state' '')
        }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $skippedWorkspaces = [System.Collections.Generic.List[object]]::new()
    $unknownCapacityIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($scan in $ScanResults) {
        foreach ($workspace in @(Get-InventoryProperty $scan 'workspaces' @())) {
            $workspaceId = [string](Get-InventoryProperty $workspace 'id' '')
            $workspaceName = [string](Get-InventoryProperty $workspace 'name' '')
            $capacityId = [string](Get-InventoryProperty $workspace 'capacityId' '')

            if (-not $capacityId) {
                $skippedWorkspaces.Add([pscustomobject]@{
                    WorkspaceId = $workspaceId
                    WorkspaceName = $workspaceName
                    Reason = 'NoCapacityAssigned'
                })
                continue
            }

            $capacityName = ''
            if ($capacityLookup.ContainsKey($capacityId)) {
                $capacityName = $capacityLookup[$capacityId].CapacityName
            } else {
                [void]$unknownCapacityIds.Add($capacityId)
            }

            foreach ($dataset in @(Get-InventoryProperty $workspace 'datasets' @())) {
                $createdRaw = [string](Get-InventoryProperty $dataset 'createdDate' '')
                $candidates.Add([pscustomobject]@{
                    CapacityId = $capacityId
                    CapacityName = $capacityName
                    WorkspaceId = $workspaceId
                    WorkspaceName = $workspaceName
                    SemanticModelId = [string](Get-InventoryProperty $dataset 'id' '')
                    SemanticModelName = [string](Get-InventoryProperty $dataset 'name' '')
                    CreatedRaw = $createdRaw
                    CreatedAt = ConvertTo-InventoryTimestamp -Value $createdRaw
                    TargetStorageMode = [string](Get-InventoryProperty $dataset 'targetStorageMode' '')
                })
            }
        }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    $duplicatesResolved = 0
    $groups = $candidates | Group-Object { '{0}|{1}' -f $_.WorkspaceId, $_.SemanticModelName.ToLowerInvariant() }

    foreach ($group in $groups) {
        if ($group.Count -eq 1) {
            $selected.Add($group.Group[0])
            continue
        }

        $undated = @($group.Group | Where-Object { $null -eq $_.CreatedAt })
        if ($undated.Count -gt 0) {
            $sample = $group.Group[0]
            throw ("Cannot determine the most recent semantic model named '{0}' in workspace '{1}' [{2}] because {3} of {4} duplicates have a missing or invalid creation timestamp." -f `
                $sample.SemanticModelName, $sample.WorkspaceName, $sample.WorkspaceId, $undated.Count, $group.Count)
        }

        $duplicatesResolved += $group.Count - 1
        # Newest creation time wins; semantic model ID breaks exact ties deterministically.
        $selected.Add((@($group.Group | Sort-Object -Property @{ Expression = 'CreatedAt'; Descending = $true }, @{ Expression = 'SemanticModelId'; Descending = $true })[0]))
    }

    $undatedSingles = @($selected | Where-Object { $null -eq $_.CreatedAt -and $_.CreatedRaw })
    $missingCreatedDate = @($selected | Where-Object { $null -eq $_.CreatedAt })

    $rows = @($selected | Sort-Object -Property CapacityName, WorkspaceName, SemanticModelName, CapacityId, WorkspaceId, SemanticModelId)

    return [pscustomobject]@{
        Rows = $rows
        SkippedWorkspaces = $skippedWorkspaces.ToArray()
        UnknownCapacityIds = @($unknownCapacityIds)
        DuplicateModelsResolved = $duplicatesResolved
        ModelsMissingCreatedDate = $missingCreatedDate.Count
        ModelsWithUnparsableCreatedDate = $undatedSingles.Count
    }
}

function ConvertTo-InventoryCsvRow {
    <#
        .SYNOPSIS
        Projects internal rows onto the exact exported column contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)

    return @($Rows | ForEach-Object {
        [pscustomobject][ordered]@{
            CapacityName = $_.CapacityName
            CapacityId = $_.CapacityId
            WorkspaceName = $_.WorkspaceName
            WorkspaceId = $_.WorkspaceId
            SemanticModelName = $_.SemanticModelName
            SemanticModelCreatedAt = if ($_.CreatedAt) { $_.CreatedAt.UtcDateTime.ToString('o') } else { '' }
            TargetStorageMode = $_.TargetStorageMode
        }
    })
}

function Export-TenantInventoryCsv {
    <#
        .SYNOPSIS
        Writes the inventory CSV atomically so a failure never replaces a good file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Force -Path $directory)
    }

    $csvRows = @(ConvertTo-InventoryCsvRow -Rows $Rows)
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        if ($csvRows.Count -gt 0) {
            $csvRows | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding utf8
        } else {
            Set-Content -LiteralPath $temporaryPath -Value (($script:InventoryColumns | ForEach-Object { '"' + $_ + '"' }) -join ',') -Encoding utf8
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }

    return $csvRows.Count
}

Export-ModuleMember -Function Get-InventoryColumnName, ConvertTo-InventoryTimestamp, ConvertTo-TenantInventory, `
    ConvertTo-InventoryCsvRow, Export-TenantInventoryCsv
