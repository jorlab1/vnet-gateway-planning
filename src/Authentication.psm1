Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $effectiveArguments = @($Arguments)
    if ($effectiveArguments -notcontains '--only-show-errors') { $effectiveArguments += '--only-show-errors' }
    $output = & az @effectiveArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join [Environment]::NewLine)"
    }

    if (-not $output) {
        return $null
    }

    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Connect-EstateIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Configuration)

    $auth = $Configuration.Authentication
    if ($auth.Mode -eq 'ServicePrincipal') {
        if (-not $auth.ClientId -or -not $Configuration.TenantId) {
            throw 'ServicePrincipal authentication requires TenantId and ClientId.'
        }

        if ($auth.CertificatePath) {
            Invoke-AzCliJson -Arguments @(
                'login', '--service-principal', '--allow-no-subscriptions',
                '--tenant', $Configuration.TenantId,
                '--username', $auth.ClientId,
                '--certificate', $auth.CertificatePath,
                '--output', 'json'
            ) | Out-Null
            return
        }

        $secretVariable = $auth.ClientSecretEnvironmentVariable
        $secret = [Environment]::GetEnvironmentVariable($secretVariable)
        if (-not $secret) {
            throw "Set the $secretVariable environment variable or configure CertificatePath."
        }

        Invoke-AzCliJson -Arguments @(
            'login', '--service-principal', '--allow-no-subscriptions',
            '--tenant', $Configuration.TenantId,
            '--username', $auth.ClientId,
            '--password', $secret,
            '--output', 'json'
        ) | Out-Null
        return
    }

    $account = & az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        $arguments = @('login', '--allow-no-subscriptions', '--output', 'json')
        if ($Configuration.TenantId -and $Configuration.TenantId -ne '<tenant-guid>') {
            $arguments += @('--tenant', $Configuration.TenantId)
        }
        Invoke-AzCliJson -Arguments $arguments | Out-Null
    }
}

function Get-EstateAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PowerBI', 'Fabric', 'AzureResourceManager')]
        [string]$Resource
    )

    $resourceUri = switch ($Resource) {
        'PowerBI' { 'https://analysis.windows.net/powerbi/api' }
        'Fabric' { 'https://api.fabric.microsoft.com' }
        'AzureResourceManager' { 'https://management.azure.com' }
    }

    $token = Invoke-AzCliJson -Arguments @(
        'account', 'get-access-token',
        '--resource', $resourceUri,
        '--output', 'json'
    )

    return $token.accessToken
}

Export-ModuleMember -Function Connect-EstateIdentity, Get-EstateAccessToken
