Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-InventoryEnvironmentFile {
    <#
        .SYNOPSIS
        Parses a .env file into a hashtable without touching the process environment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $values = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $values }

    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) {
            throw "Malformed entry on line $lineNumber of $Path. Expected KEY=VALUE."
        }

        $key = $trimmed.Substring(0, $separator).Trim()
        if (-not $key) {
            throw "Missing key on line $lineNumber of $Path."
        }
        if ($values.ContainsKey($key)) {
            throw "Duplicate entry '$key' on line $lineNumber of $Path."
        }

        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            if (($first -eq '"' -or $first -eq "'") -and $value[-1] -eq $first) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }

    return $values
}

function Resolve-InventorySetting {
    <#
        .SYNOPSIS
        Resolves a non-secret setting from an explicit value, the process
        environment, then the optional .env file.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ExplicitValue,
        [Parameter(Mandatory)][string]$VariableName,
        [hashtable]$FileValues,
        [switch]$Required
    )

    $candidates = [ordered]@{
        Parameter = $ExplicitValue
        Environment = [Environment]::GetEnvironmentVariable($VariableName)
        EnvironmentFile = if ($FileValues -and $FileValues.ContainsKey($VariableName)) { $FileValues[$VariableName] } else { $null }
    }

    foreach ($source in $candidates.Keys) {
        $value = $candidates[$source]
        if ($value) { return [pscustomobject]@{ Value = $value.Trim(); Source = $source } }
    }

    if ($Required) {
        throw "$VariableName was not found. Pass it as a parameter, set it as an environment variable, or add it to the .env file."
    }
    return [pscustomobject]@{ Value = ''; Source = 'None' }
}

function Resolve-InventorySecret {
    <#
        .SYNOPSIS
        Resolves the client secret from the process environment, the optional
        .env file, then the Windows user-scoped environment variable.

        The value is never written to output, logs, or error messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VariableName,
        [hashtable]$FileValues
    )

    $value = [Environment]::GetEnvironmentVariable($VariableName)
    if ($value) { return [pscustomobject]@{ Value = $value; Source = 'Environment' } }

    if ($FileValues -and $FileValues.ContainsKey($VariableName) -and $FileValues[$VariableName]) {
        return [pscustomobject]@{ Value = $FileValues[$VariableName]; Source = 'EnvironmentFile' }
    }

    if ($IsWindows) {
        $userValue = [Environment]::GetEnvironmentVariable($VariableName, 'User')
        if ($userValue) { return [pscustomobject]@{ Value = $userValue; Source = 'WindowsUserScope' } }
    }

    throw "The secret environment variable '$VariableName' was not found. Set it for the current process, add it to the .env file, or define it as a Windows user environment variable."
}

function Get-InventoryCredential {
    <#
        .SYNOPSIS
        Builds the full service-principal credential set for the inventory run.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$TenantId,
        [AllowEmptyString()][string]$ClientId,
        [AllowEmptyString()][string]$ClientSecretEnvironmentVariable = '',
        [AllowEmptyString()][string]$EnvironmentFilePath
    )

    $fileValues = Import-InventoryEnvironmentFile -Path $EnvironmentFilePath
    $tenant = Resolve-InventorySetting -ExplicitValue $TenantId -VariableName 'POWERBI_TENANT_ID' -FileValues $fileValues -Required
    $client = Resolve-InventorySetting -ExplicitValue $ClientId -VariableName 'POWERBI_CLIENT_ID' -FileValues $fileValues -Required

    # The name of the secret variable is itself configurable, so a repeat run
    # needs no arguments even when the secret lives under a custom name.
    $secretVariable = Resolve-InventorySetting -ExplicitValue $ClientSecretEnvironmentVariable `
        -VariableName 'POWERBI_CLIENT_SECRET_VARIABLE' -FileValues $fileValues
    $secretVariableName = if ($secretVariable.Value) { $secretVariable.Value } else { 'POWERBI_CLIENT_SECRET' }

    $secret = Resolve-InventorySecret -VariableName $secretVariableName -FileValues $fileValues

    return [pscustomobject]@{
        TenantId = $tenant.Value
        TenantIdSource = $tenant.Source
        ClientId = $client.Value
        ClientIdSource = $client.Source
        ClientSecret = $secret.Value
        ClientSecretSource = $secret.Source
        ClientSecretVariableName = $secretVariableName
    }
}

Export-ModuleMember -Function Import-InventoryEnvironmentFile, Resolve-InventorySetting, Resolve-InventorySecret, Get-InventoryCredential
