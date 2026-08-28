$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\InventoryConfiguration.psm1') -Force

Describe 'Environment file parsing' {
    It 'reads key/value pairs and ignores comments and blank lines' {
        $path = Join-Path $TestDrive 'good.env'
        @(
            '# comment'
            ''
            'POWERBI_TENANT_ID=tenant-1'
            'POWERBI_CLIENT_ID = client-1 '
            'POWERBI_CLIENT_SECRET="quoted-secret"'
        ) | Set-Content -LiteralPath $path

        $values = Import-InventoryEnvironmentFile -Path $path
        if ($values['POWERBI_TENANT_ID'] -ne 'tenant-1') { throw 'Tenant ID was not parsed.' }
        if ($values['POWERBI_CLIENT_ID'] -ne 'client-1') { throw 'Whitespace was not trimmed.' }
        if ($values['POWERBI_CLIENT_SECRET'] -ne 'quoted-secret') { throw 'Quotes were not stripped.' }
    }

    It 'returns an empty set when the file does not exist' {
        $values = Import-InventoryEnvironmentFile -Path (Join-Path $TestDrive 'missing.env')
        if ($values.Count -ne 0) { throw 'Expected no values for a missing file.' }
    }

    It 'rejects malformed lines' {
        $path = Join-Path $TestDrive 'malformed.env'
        'NOT_A_PAIR' | Set-Content -LiteralPath $path
        $threw = $false
        try { Import-InventoryEnvironmentFile -Path $path } catch { $threw = $true }
        if (-not $threw) { throw 'Expected a malformed-entry error.' }
    }

    It 'rejects duplicate keys' {
        $path = Join-Path $TestDrive 'duplicate.env'
        @('POWERBI_CLIENT_ID=a', 'POWERBI_CLIENT_ID=b') | Set-Content -LiteralPath $path
        $threw = $false
        try { Import-InventoryEnvironmentFile -Path $path } catch { $threw = $true }
        if (-not $threw) { throw 'Expected a duplicate-entry error.' }
    }
}

Describe 'Setting resolution' {
    It 'prefers an explicit parameter over other sources' {
        $resolved = Resolve-InventorySetting -ExplicitValue 'from-parameter' -VariableName 'POWERBI_TENANT_ID' `
            -FileValues @{ POWERBI_TENANT_ID = 'from-file' }
        if ($resolved.Value -ne 'from-parameter') { throw "Got $($resolved.Value)." }
        if ($resolved.Source -ne 'Parameter') { throw "Got source $($resolved.Source)." }
    }

    It 'prefers a process environment variable over the environment file' {
        $name = 'INVENTORY_TEST_TENANT'
        [Environment]::SetEnvironmentVariable($name, 'from-process')
        try {
            $resolved = Resolve-InventorySetting -ExplicitValue '' -VariableName $name -FileValues @{ $name = 'from-file' }
            if ($resolved.Value -ne 'from-process') { throw "Got $($resolved.Value)." }
            if ($resolved.Source -ne 'Environment') { throw "Got source $($resolved.Source)." }
        }
        finally { [Environment]::SetEnvironmentVariable($name, $null) }
    }

    It 'falls back to the environment file when nothing else is set' {
        $name = 'INVENTORY_TEST_UNSET'
        $resolved = Resolve-InventorySetting -ExplicitValue '' -VariableName $name -FileValues @{ $name = 'from-file' }
        if ($resolved.Source -ne 'EnvironmentFile') { throw "Got source $($resolved.Source)." }
    }

    It 'throws a actionable error when a required value is missing' {
        $threw = $false
        $message = ''
        try { Resolve-InventorySetting -ExplicitValue '' -VariableName 'INVENTORY_TEST_MISSING' -FileValues @{} -Required }
        catch { $threw = $true; $message = $_.Exception.Message }
        if (-not $threw) { throw 'Expected a missing-value error.' }
        if ($message -notlike '*INVENTORY_TEST_MISSING*') { throw "Error did not name the variable: $message" }
    }
}

Describe 'Secret resolution' {
    It 'reads the secret from the process environment' {
        $name = 'INVENTORY_TEST_SECRET'
        [Environment]::SetEnvironmentVariable($name, 'shhh')
        try {
            $resolved = Resolve-InventorySecret -VariableName $name -FileValues @{}
            if ($resolved.Value -ne 'shhh') { throw 'Secret was not resolved.' }
            if ($resolved.Source -ne 'Environment') { throw "Got source $($resolved.Source)." }
        }
        finally { [Environment]::SetEnvironmentVariable($name, $null) }
    }

    It 'never includes the secret value in the missing-secret error' {
        $threw = $false
        $message = ''
        try { Resolve-InventorySecret -VariableName 'INVENTORY_TEST_NO_SECRET' -FileValues @{} }
        catch { $threw = $true; $message = $_.Exception.Message }
        if (-not $threw) { throw 'Expected a missing-secret error.' }
        if ($message -notlike '*INVENTORY_TEST_NO_SECRET*') { throw "Error did not name the variable: $message" }
    }

    It 'builds a full credential set without a .env file' {
        [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', 'tenant-x')
        [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', 'client-x')
        [Environment]::SetEnvironmentVariable('CUSTOM_SECRET_NAME', 'secret-x')
        try {
            $credential = Get-InventoryCredential -ClientSecretEnvironmentVariable 'CUSTOM_SECRET_NAME' `
                -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
            if ($credential.TenantId -ne 'tenant-x') { throw 'Tenant ID was not resolved.' }
            if ($credential.ClientId -ne 'client-x') { throw 'Client ID was not resolved.' }
            if ($credential.ClientSecret -ne 'secret-x') { throw 'Secret was not resolved.' }
            if ($credential.ClientSecretVariableName -ne 'CUSTOM_SECRET_NAME') { throw 'Secret variable name was not recorded.' }
        }
        finally {
            [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', $null)
            [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', $null)
            [Environment]::SetEnvironmentVariable('CUSTOM_SECRET_NAME', $null)
        }
    }

    It 'lets the .env file name the secret variable so no argument is needed' {
        $path = Join-Path $TestDrive 'named-secret.env'
        @(
            'POWERBI_TENANT_ID=tenant-y'
            'POWERBI_CLIENT_ID=client-y'
            'POWERBI_CLIENT_SECRET_VARIABLE=CUSTOM_POINTER_NAME'
        ) | Set-Content -LiteralPath $path
        [Environment]::SetEnvironmentVariable('CUSTOM_POINTER_NAME', 'secret-y')
        try {
            $credential = Get-InventoryCredential -EnvironmentFilePath $path
            if ($credential.ClientSecretVariableName -ne 'CUSTOM_POINTER_NAME') {
                throw "Expected the configured secret variable name, got $($credential.ClientSecretVariableName)."
            }
            if ($credential.ClientSecret -ne 'secret-y') { throw 'Secret was not resolved through the configured name.' }
        }
        finally { [Environment]::SetEnvironmentVariable('CUSTOM_POINTER_NAME', $null) }
    }

    It 'defaults to POWERBI_CLIENT_SECRET when no name is configured' {
        [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', 'tenant-z')
        [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', 'client-z')
        [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_SECRET', 'secret-z')
        try {
            $credential = Get-InventoryCredential -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
            if ($credential.ClientSecretVariableName -ne 'POWERBI_CLIENT_SECRET') {
                throw "Expected the default secret variable name, got $($credential.ClientSecretVariableName)."
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', $null)
            [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', $null)
            [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_SECRET', $null)
        }
    }
}

Describe 'Authentication mode selection' {
    It 'defaults to service principal when no mode is configured' {
        [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', 'tenant-a')
        [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', 'client-a')
        [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_SECRET', 'secret-a')
        try {
            $credential = Get-InventoryCredential -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
            if ($credential.AuthMode -ne 'ServicePrincipal') { throw "Expected ServicePrincipal, got $($credential.AuthMode)." }
            if ($credential.AuthModeSource -ne 'Default') { throw 'Mode source should report the default.' }
        }
        finally {
            [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', $null)
            [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', $null)
            [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_SECRET', $null)
        }
    }

    It 'reads the mode from the .env file so no argument is needed' {
        $path = Join-Path $TestDrive 'mode.env'
        @('POWERBI_AUTH_MODE=AzureCli') | Set-Content -LiteralPath $path
        $credential = Get-InventoryCredential -EnvironmentFilePath $path
        if ($credential.AuthMode -ne 'AzureCli') { throw "Expected AzureCli, got $($credential.AuthMode)." }
        if ($credential.AuthModeSource -ne 'EnvironmentFile') { throw 'Mode source should be the .env file.' }
    }

    It 'accepts the mode case-insensitively and normalizes it' {
        $credential = Get-InventoryCredential -AuthMode 'azurecli' -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
        if ($credential.AuthMode -ne 'AzureCli') { throw "Mode was not normalized, got $($credential.AuthMode)." }
    }

    It 'rejects an unknown mode' {
        $threw = $false
        try { Get-InventoryCredential -AuthMode 'Certificate' -EnvironmentFilePath (Join-Path $TestDrive 'absent.env') }
        catch { $threw = $true }
        if (-not $threw) { throw 'An unknown authentication mode should fail.' }
    }

    It 'requires no secret and no client for Azure CLI mode' {
        $credential = Get-InventoryCredential -AuthMode 'AzureCli' -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
        if ($credential.ClientSecret) { throw 'Azure CLI mode must not resolve a secret.' }
        if ($credential.ClientSecretSource -ne 'NotRequired') { throw 'Secret source should report NotRequired.' }
        if ($credential.TenantId) { throw 'Azure CLI mode should not demand a tenant.' }
    }

    It 'falls back to the Azure CLI public client for device code sign-in' {
        [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', 'tenant-b')
        try {
            $credential = Get-InventoryCredential -AuthMode 'DeviceCode' -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
            if ($credential.ClientId -ne '04b07795-8ddb-461a-bbee-02f9e1bf7b46') { throw "Unexpected default client $($credential.ClientId)." }
            if ($credential.ClientIdSource -ne 'DefaultPublicClient') { throw 'Client source should report the default public client.' }
            if ($credential.ClientSecret) { throw 'Device code mode must not resolve a secret.' }
        }
        finally { [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', $null) }
    }

    It 'prefers an explicitly configured client over the default public client' {
        [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', 'tenant-c')
        [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', 'my-public-client')
        try {
            $credential = Get-InventoryCredential -AuthMode 'DeviceCode' -EnvironmentFilePath (Join-Path $TestDrive 'absent.env')
            if ($credential.ClientId -ne 'my-public-client') { throw 'A configured client ID should win.' }
        }
        finally {
            [Environment]::SetEnvironmentVariable('POWERBI_TENANT_ID', $null)
            [Environment]::SetEnvironmentVariable('POWERBI_CLIENT_ID', $null)
        }
    }

    It 'still requires a tenant for device code sign-in' {
        $threw = $false
        try { Get-InventoryCredential -AuthMode 'DeviceCode' -EnvironmentFilePath (Join-Path $TestDrive 'absent.env') }
        catch { $threw = $true }
        if (-not $threw) { throw 'Device code mode should require a tenant ID.' }
    }
}
