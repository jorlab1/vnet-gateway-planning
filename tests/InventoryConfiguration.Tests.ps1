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
