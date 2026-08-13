Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-EstateRestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$AccessToken,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [object]$Body,
        [int]$MaximumAttempts = 6
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $parameters = @{
                Uri = $Uri
                Method = $Method
                Headers = $headers
                ContentType = 'application/json'
            }
            if ($PSBoundParameters.ContainsKey('Body')) {
                $parameters.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
            }
            return Invoke-RestMethod @parameters
        }
        catch {
            $response = $_.Exception.Response
            $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
            if ($attempt -eq $MaximumAttempts -or $statusCode -notin 429, 500, 502, 503, 504) {
                $requestId = ''
                if ($response -and $response.Headers) {
                    $headerValues = $null
                    if ($response.Headers.TryGetValues('x-ms-request-id', [ref]$headerValues)) {
                        $requestId = $headerValues -join ','
                    }
                }
                throw "REST $Method $Uri failed with status $statusCode. RequestId=$requestId. $($_.Exception.Message)"
            }

            $retryAfter = 0
            if ($response -and $response.Headers) {
                $values = $null
                if ($response.Headers.TryGetValues('Retry-After', [ref]$values) -and $values) {
                    [void][int]::TryParse($values[0], [ref]$retryAfter)
                }
            }
            if ($retryAfter -le 0) { $retryAfter = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
            Start-Sleep -Seconds $retryAfter
        }
    }
}

function Get-PowerBIAdminGroups {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccessToken)

    $uri = 'https://api.powerbi.com/v1.0/myorg/admin/groups?$top=5000'
    $response = Invoke-EstateRestMethod -Uri $uri -AccessToken $AccessToken
    return @($response.value)
}

function Get-PowerBIAdminCapacities {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccessToken)

    $uri = 'https://api.powerbi.com/v1.0/myorg/admin/capacities'
    $response = Invoke-EstateRestMethod -Uri $uri -AccessToken $AccessToken
    return @($response.value)
}

function Get-FabricCapacities {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccessToken)

    $uri = 'https://api.fabric.microsoft.com/v1/capacities'
    $results = [System.Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-EstateRestMethod -Uri $uri -AccessToken $AccessToken
        foreach ($item in @($response.value)) { $results.Add($item) }
        $continuationToken = if ($response.PSObject.Properties['continuationToken']) { $response.continuationToken } else { $null }
        $uri = if ($continuationToken) {
            "https://api.fabric.microsoft.com/v1/capacities?continuationToken=$([uri]::EscapeDataString($continuationToken))"
        } else { $null }
    } while ($uri)
    return $results.ToArray()
}

Export-ModuleMember -Function Invoke-EstateRestMethod, Get-PowerBIAdminGroups, Get-PowerBIAdminCapacities, Get-FabricCapacities
