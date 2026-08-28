Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AdminBaseUri = 'https://api.powerbi.com/v1.0/myorg/admin'
$script:MaximumWorkspacesPerScan = 100
$script:WorkspacePageSize = 5000

function Get-ResponseHeaderValue {
    param($Response, [string]$Name)

    if (-not $Response -or -not $Response.Headers) { return '' }
    $values = $null
    if ($Response.Headers.TryGetValues($Name, [ref]$values) -and $values) {
        return ($values -join ',')
    }
    return ''
}

function Invoke-InventoryAdminRequest {
    <#
        .SYNOPSIS
        Calls a Power BI admin endpoint with throttling-aware retries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$AccessToken,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
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
            # A transport-level failure raises an exception without a Response
            # property, which strict mode would otherwise turn into a confusing
            # secondary error inside the handler.
            $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
            $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
            $isRetryable = $statusCode -in 429, 500, 502, 503, 504

            # Transport failures have no status code but are usually transient.
            if ($statusCode -eq 0 -and $_.Exception -is [Net.Http.HttpRequestException]) { $isRetryable = $true }

            if ($attempt -eq $MaximumAttempts -or -not $isRetryable) {
                $requestId = Get-ResponseHeaderValue -Response $response -Name 'RequestId'
                if (-not $requestId) {
                    $requestId = Get-ResponseHeaderValue -Response $response -Name 'x-ms-request-id'
                }
                $hint = switch ($statusCode) {
                    401 { ' The token was rejected. Confirm the Power BI token audience and that the caller is authorized for read-only admin APIs.' }
                    403 { ' Access was denied. A service principal must be in a security group allowed by the Fabric admin API tenant settings; a user must hold the Fabric Administrator role.' }
                    default { '' }
                }
                throw "Admin API $Method $Uri failed with status $statusCode. RequestId=$requestId.$hint $($_.Exception.Message)"
            }

            $retryAfter = 0
            $retryHeader = Get-ResponseHeaderValue -Response $response -Name 'Retry-After'
            if ($retryHeader) { [void][int]::TryParse(($retryHeader -split ',')[0], [ref]$retryAfter) }
            if ($retryAfter -le 0) { $retryAfter = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
            $jitter = Get-Random -Minimum 0.0 -Maximum 1.0
            Start-Sleep -Seconds ([Math]::Min(90, $retryAfter + $jitter))
        }
    }
}

function Get-InventoryCapacity {
    <#
        .SYNOPSIS
        Returns every tenant capacity, including suspended and inactive ones.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccessToken)

    $response = Invoke-InventoryAdminRequest -Uri "$script:AdminBaseUri/capacities" -AccessToken $AccessToken
    return @($response.value)
}

function Get-InventoryWorkspace {
    <#
        .SYNOPSIS
        Returns all active, non-personal tenant workspaces, paging the full result set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$PageSize = $script:WorkspacePageSize
    )

    $workspaces = [System.Collections.Generic.List[object]]::new()
    $skip = 0
    do {
        $uri = "$script:AdminBaseUri/groups?`$top=$PageSize&`$skip=$skip"
        $response = Invoke-InventoryAdminRequest -Uri $uri -AccessToken $AccessToken
        $page = @($response.value)
        foreach ($workspace in $page) { $workspaces.Add($workspace) }
        $skip += $PageSize
    } while ($page.Count -eq $PageSize)

    return @($workspaces | Where-Object {
        $_.state -ne 'Deleted' -and $_.type -ne 'PersonalGroup'
    })
}

function Start-InventoryWorkspaceScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$WorkspaceIds,
        [Parameter(Mandatory)][string]$AccessToken
    )

    # Only base inventory metadata is required, so every extended flag stays false.
    $uri = "$script:AdminBaseUri/workspaces/getInfo?lineage=false&datasourceDetails=false&datasetSchema=false&datasetExpressions=false&getArtifactUsers=false"
    $response = Invoke-InventoryAdminRequest -Uri $uri -AccessToken $AccessToken -Method POST -Body @{ workspaces = $WorkspaceIds }
    return $response.id
}

function Wait-InventoryWorkspaceScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScanId,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$PollSeconds = 2,
        [int]$TimeoutSeconds = 900
    )

    $statusUri = "$script:AdminBaseUri/workspaces/scanStatus/$ScanId"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $status = Invoke-InventoryAdminRequest -Uri $statusUri -AccessToken $AccessToken
        if ($status.status -eq 'Succeeded') { break }
        if ($status.status -eq 'Failed') {
            $reason = if ($status.PSObject.Properties['error'] -and $status.error) { " $($status.error.message)" } else { '' }
            throw "Workspace scan $ScanId failed.$reason"
        }
        if ([datetime]::UtcNow -gt $deadline) {
            throw "Workspace scan $ScanId did not finish within $TimeoutSeconds seconds. Last status: $($status.status)."
        }
        Start-Sleep -Seconds $PollSeconds
    }

    return Invoke-InventoryAdminRequest -Uri "$script:AdminBaseUri/workspaces/scanResult/$ScanId" -AccessToken $AccessToken
}

function Invoke-InventoryWorkspaceScan {
    <#
        .SYNOPSIS
        Scans every supplied workspace in batches of at most 100 workspace IDs.

        .DESCRIPTION
        There is no cap on the number of batches. A failed batch aborts the run
        so a partial result is never treated as a complete inventory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Workspaces,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$BatchSize = $script:MaximumWorkspacesPerScan,
        [int]$PollSeconds = 2,
        [int]$LargeRunBatchWarningThreshold = 50
    )

    $effectiveBatchSize = [Math]::Min($script:MaximumWorkspacesPerScan, [Math]::Max(1, $BatchSize))
    $results = [System.Collections.Generic.List[object]]::new()
    if ($Workspaces.Count -eq 0) { return $results.ToArray() }

    $batchCount = [Math]::Ceiling($Workspaces.Count / $effectiveBatchSize)
    if ($batchCount -gt $LargeRunBatchWarningThreshold) {
        Write-Warning "Scanning $($Workspaces.Count) workspaces in $batchCount batches. Admin scan APIs allow 500 requests per hour, so this run may be throttled."
    }

    $batchNumber = 0
    for ($offset = 0; $offset -lt $Workspaces.Count; $offset += $effectiveBatchSize) {
        $batchNumber++
        $last = [Math]::Min($offset + $effectiveBatchSize - 1, $Workspaces.Count - 1)
        $batch = @($Workspaces[$offset..$last])
        $ids = @($batch | ForEach-Object { [string]$_.id })

        Write-Verbose "Scanning batch $batchNumber of $batchCount ($($ids.Count) workspaces)."
        try {
            $scanId = Start-InventoryWorkspaceScan -WorkspaceIds $ids -AccessToken $AccessToken
            $results.Add((Wait-InventoryWorkspaceScan -ScanId $scanId -AccessToken $AccessToken -PollSeconds $PollSeconds))
        }
        catch {
            $names = @($batch | ForEach-Object { "$($_.name) [$($_.id)]" }) -join '; '
            throw "Workspace scan batch $batchNumber of $batchCount failed, so the inventory is incomplete and was not written. Workspaces in the failed batch: $names. $($_.Exception.Message)"
        }
    }

    return $results.ToArray()
}

Export-ModuleMember -Function Invoke-InventoryAdminRequest, Get-InventoryCapacity, Get-InventoryWorkspace, `
    Start-InventoryWorkspaceScan, Wait-InventoryWorkspaceScan, Invoke-InventoryWorkspaceScan
