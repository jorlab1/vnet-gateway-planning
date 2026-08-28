Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The inventory calls Power BI read-only admin APIs, so it must request the
# Power BI audience. A Fabric-audience token is not accepted by these endpoints.
$script:PowerBiScope = 'https://analysis.windows.net/powerbi/api/.default'

# Resource form of the same audience, used by the Azure CLI token command.
$script:PowerBiResource = 'https://analysis.windows.net/powerbi/api'

function Get-InventoryAccessToken {
    <#
        .SYNOPSIS
        Acquires a Power BI access token using the OAuth client-credentials flow.

        .DESCRIPTION
        The client secret is sent only in the encoded request body. It is never
        placed in a command argument, URL, log entry, or error message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [string]$Scope = $script:PowerBiScope
    )

    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id = $ClientId
        client_secret = $ClientSecret
        scope = $Scope
        grant_type = 'client_credentials'
    }

    try {
        $response = Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $parsed = $_.ErrorDetails.Message | ConvertFrom-Json
                $detail = " $($parsed.error): $($parsed.error_description -split "\r?\n" | Select-Object -First 1)"
            } catch {
                $detail = ''
            }
        }
        throw "Token request failed for client $ClientId in tenant $TenantId.$detail"
    }

    if (-not $response.access_token) {
        throw "Token endpoint did not return an access token for client $ClientId."
    }
    return $response.access_token
}

function Get-InventoryDeviceCodeToken {
    <#
        .SYNOPSIS
        Acquires a Power BI access token by signing in an interactive user with
        the OAuth device authorization flow.

        .DESCRIPTION
        The signed-in user must be a Fabric administrator. No secret is involved,
        and nothing is written to disk: the token lives only in memory for the
        duration of the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$Scope = $script:PowerBiScope,
        [int]$TimeoutSeconds = 300
    )

    $authority = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"

    try {
        $device = Invoke-RestMethod -Method POST -Uri "$authority/devicecode" `
            -Body @{ client_id = $ClientId; scope = $Scope } `
            -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        throw "Device code request failed for client $ClientId in tenant $TenantId. $(Get-InventoryOAuthErrorDetail -ErrorRecord $_)"
    }

    Write-Host ''
    Write-Host 'Sign in to continue:'
    Write-Host "  1. Open $($device.verification_uri)"
    Write-Host "  2. Enter code $($device.user_code)"
    Write-Host "  3. Sign in as a Fabric administrator"
    Write-Host ''

    # The authorization server dictates the polling interval; honor it and back
    # off further whenever it answers slow_down.
    $interval = if ($device.interval) { [int]$device.interval } else { 5 }
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Min($TimeoutSeconds, [int]$device.expires_in))

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $response = Invoke-RestMethod -Method POST -Uri "$authority/token" `
                -Body @{
                    client_id = $ClientId
                    grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                    device_code = $device.device_code
                } `
                -ContentType 'application/x-www-form-urlencoded'

            if (-not $response.access_token) {
                throw 'The token endpoint completed the device code flow without returning an access token.'
            }
            Write-Host 'Signed in.'
            return $response.access_token
        }
        catch {
            $code = Get-InventoryOAuthErrorCode -ErrorRecord $_
            if ($code -eq 'slow_down') { $interval += 5 }
            elseif ($code -eq 'expired_token') { throw 'The device code expired before sign-in completed. Run the command again.' }
            elseif ($code -eq 'authorization_declined') { throw 'Sign-in was declined.' }
            elseif ($code -ne 'authorization_pending') {
                throw "Device code sign-in failed. $(Get-InventoryOAuthErrorDetail -ErrorRecord $_)"
            }
            # authorization_pending and slow_down simply mean "keep polling".
        }
    }

    throw "Device code sign-in was not completed within $TimeoutSeconds seconds."
}

function Get-InventoryAzureCliToken {
    <#
        .SYNOPSIS
        Reuses the Azure CLI sign-in to get a Power BI access token.

        .DESCRIPTION
        Requires 'az login' to have been completed by a Fabric administrator.
        The token is read from stdout and never persisted by this module.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId = '',
        [string]$Resource = $script:PowerBiResource
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "The Azure CLI ('az') was not found on PATH. Install it, or use -AuthMode DeviceCode or ServicePrincipal."
    }

    $arguments = @('account', 'get-access-token', '--resource', $Resource, '--output', 'json')
    if ($TenantId) { $arguments += @('--tenant', $TenantId) }

    $output = & az @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        throw "Azure CLI could not issue a Power BI token. Run 'az login' as a Fabric administrator first.`n$message"
    }

    try {
        $token = ($output | Out-String | ConvertFrom-Json).accessToken
    }
    catch {
        throw 'Azure CLI returned output that could not be parsed as a token response.'
    }

    if (-not $token) { throw 'Azure CLI returned an empty access token.' }
    return $token
}

function Get-InventoryOAuthErrorCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try { return ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).error } catch { return '' }
    }
    return ''
}

function Get-InventoryOAuthErrorDetail {
    <#
        .SYNOPSIS
        Extracts the OAuth error code and first description line, so the raw
        response body never reaches the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try {
            $parsed = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
            $description = ($parsed.error_description -split "\r?\n" | Select-Object -First 1)
            return "$($parsed.error): $description"
        }
        catch { return '' }
    }
    return ''
}

function Get-InventoryToken {
    <#
        .SYNOPSIS
        Acquires a Power BI access token using the requested authentication mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ServicePrincipal', 'DeviceCode', 'AzureCli')][string]$AuthMode,
        [AllowEmptyString()][string]$TenantId = '',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$ClientSecret = '',
        [int]$TimeoutSeconds = 300
    )

    switch ($AuthMode) {
        'ServicePrincipal' {
            return Get-InventoryAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        }
        'DeviceCode' {
            return Get-InventoryDeviceCodeToken -TenantId $TenantId -ClientId $ClientId -TimeoutSeconds $TimeoutSeconds
        }
        'AzureCli' {
            return Get-InventoryAzureCliToken -TenantId $TenantId
        }
    }
}

Export-ModuleMember -Function Get-InventoryAccessToken, Get-InventoryDeviceCodeToken,
    Get-InventoryAzureCliToken, Get-InventoryToken
