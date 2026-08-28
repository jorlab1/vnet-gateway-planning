$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\InventoryAuthentication.psm1') -Force

Describe 'Token acquisition dispatch' {
    It 'uses the client credentials flow for service principal mode' {
        Mock -ModuleName InventoryAuthentication Get-InventoryAccessToken { 'sp-token' }
        $token = Get-InventoryToken -AuthMode 'ServicePrincipal' -TenantId 't' -ClientId 'c' -ClientSecret 's'
        if ($token -ne 'sp-token') { throw 'Service principal mode did not use the client credentials flow.' }
    }

    It 'uses the device code flow for device code mode' {
        Mock -ModuleName InventoryAuthentication Get-InventoryDeviceCodeToken { 'device-token' }
        $token = Get-InventoryToken -AuthMode 'DeviceCode' -TenantId 't' -ClientId 'c'
        if ($token -ne 'device-token') { throw 'Device code mode did not use the device code flow.' }
    }

    It 'uses the Azure CLI for Azure CLI mode' {
        Mock -ModuleName InventoryAuthentication Get-InventoryAzureCliToken { 'cli-token' }
        $token = Get-InventoryToken -AuthMode 'AzureCli'
        if ($token -ne 'cli-token') { throw 'Azure CLI mode did not use the Azure CLI.' }
    }

    It 'rejects an unsupported mode' {
        $threw = $false
        try { Get-InventoryToken -AuthMode 'Certificate' } catch { $threw = $true }
        if (-not $threw) { throw 'An unsupported mode should be rejected.' }
    }
}

Describe 'Device code sign-in' {
    It 'polls until sign-in completes and returns the token' {
        Mock -ModuleName InventoryAuthentication Start-Sleep {}
        Mock -ModuleName InventoryAuthentication Invoke-RestMethod {
            if ($Uri -like '*devicecode*') {
                return [pscustomobject]@{
                    device_code = 'dc'
                    user_code = 'ABC-123'
                    verification_uri = 'https://microsoft.com/devicelogin'
                    interval = 1
                    expires_in = 900
                }
            }
            return [pscustomobject]@{ access_token = 'user-token' }
        }

        $token = Get-InventoryDeviceCodeToken -TenantId 't' -ClientId 'c'
        if ($token -ne 'user-token') { throw "Expected the delegated token, got $token." }
    }

    It 'requests the Power BI audience rather than the Fabric audience' {
        Mock -ModuleName InventoryAuthentication Start-Sleep {}
        Mock -ModuleName InventoryAuthentication Invoke-RestMethod {
            if ($Uri -like '*devicecode*') {
                if ($Body['scope'] -ne 'https://analysis.windows.net/powerbi/api/.default') {
                    throw "Unexpected scope $($Body['scope'])."
                }
                return [pscustomobject]@{
                    device_code = 'dc'; user_code = 'X'; verification_uri = 'https://example'
                    interval = 1; expires_in = 900
                }
            }
            return [pscustomobject]@{ access_token = 'user-token' }
        }

        $null = Get-InventoryDeviceCodeToken -TenantId 't' -ClientId 'c'
    }

    It 'stops waiting once the sign-in window has elapsed' {
        Mock -ModuleName InventoryAuthentication Start-Sleep {}
        Mock -ModuleName InventoryAuthentication Invoke-RestMethod {
            if ($Uri -like '*devicecode*') {
                return [pscustomobject]@{
                    device_code = 'dc'; user_code = 'X'; verification_uri = 'https://example'
                    interval = 1; expires_in = 900
                }
            }
            throw 'still pending'
        }

        $threw = $false
        try { Get-InventoryDeviceCodeToken -TenantId 't' -ClientId 'c' -TimeoutSeconds 0 }
        catch { $threw = $true }
        if (-not $threw) { throw 'An unfinished sign-in should fail rather than hang.' }
    }
}

Describe 'Azure CLI token' {
    It 'explains what to do when the Azure CLI is missing' {
        Mock -ModuleName InventoryAuthentication Get-Command { $null }
        $message = ''
        try { Get-InventoryAzureCliToken } catch { $message = $_.Exception.Message }
        if ($message -notlike '*az login*' -and $message -notlike "*'az'*") {
            throw "The error should name the Azure CLI, got: $message"
        }
    }
}
