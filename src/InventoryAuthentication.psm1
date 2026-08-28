Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The inventory calls Power BI read-only admin APIs, so it must request the
# Power BI audience. A Fabric-audience token is not accepted by these endpoints.
$script:PowerBiScope = 'https://analysis.windows.net/powerbi/api/.default'

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

Export-ModuleMember -Function Get-InventoryAccessToken
