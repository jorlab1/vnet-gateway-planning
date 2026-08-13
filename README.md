# Power BI VNet Gateway Planning

Read-only PowerShell tooling to inventory a Power BI estate, observe refresh behavior, size VNet gateway clusters, and assess whether existing Fabric capacities need to be scaled or supplemented with dedicated capacities.

Licensed under the [MIT License](LICENSE).

## Prerequisites

- PowerShell 7
- Azure CLI
- A Fabric administrator account, or a service principal enabled for Power BI/Fabric admin APIs
- Power BI tenant settings that allow service principals and Admin API metadata scanning when service-principal authentication is used
- Access to the Fabric Capacity Metrics app, or an exported utilization CSV, for capacity recommendations

The scripts do not install modules or persist credentials. Service-principal secrets must be supplied through the configured environment variable; certificate authentication is preferred. Azure CLI secret authentication passes the secret to the `az` process, so use certificate authentication where process-argument visibility is a concern.

## Authentication

The scripts use Azure CLI to authenticate and then request separate access tokens for the Power BI and Fabric APIs.

| | Interactive user | Service principal (SPN) |
|---|---|---|
| Best for | Initial assessment, troubleshooting, and manually run inventories | Scheduled collection, CI/CD, and unattended operation |
| Identity | A named Entra ID user | An Entra app registration/service principal |
| Sign-in | Browser or device-code sign-in; an existing Azure CLI session is reused | Client certificate or client secret |
| MFA | Supported | Not applicable |
| Required configuration | `Mode`, `TenantId` | `Mode`, `TenantId`, `ClientId`, plus certificate or secret settings |
| Tenant administration | User generally needs the Fabric administrator role | SPN must be allowed by the relevant Power BI/Fabric tenant settings |
| Refresh-history access | Caller needs write access to each semantic model | SPN needs write access to each semantic model/workspace |
| Recommended use | Ad hoc execution | Daily observation collection |

### Interactive user authentication

Use this mode when an administrator runs the scripts directly:

```powershell
TenantId = '00000000-0000-0000-0000-000000000000'
Authentication = @{
    Mode = 'Interactive'
    ClientId = ''
    CertificatePath = ''
    ClientSecretEnvironmentVariable = 'POWERBI_CLIENT_SECRET'
}
```

`ClientId`, `CertificatePath`, and `ClientSecretEnvironmentVariable` aren't used in interactive mode.

Before running the inventory, sign in to the intended tenant:

```powershell
az login --allow-no-subscriptions `
  --tenant 00000000-0000-0000-0000-000000000000

az account show --query "{tenantId:tenantId,user:user.name}" --output table
```

If Azure CLI already has an authenticated session, the script reuses it. Confirm that session belongs to the configured tenant, particularly when you work with multiple tenants.

The user should be a Fabric administrator for tenant-level workspace scanning and activity-log access. The refresh-history API additionally requires write permission on each semantic model. Models the user can't access are recorded in `data-quality-exceptions.csv`.

### Service principal authentication

Use this mode for unattended or scheduled execution:

```powershell
TenantId = '00000000-0000-0000-0000-000000000000'
Authentication = @{
    Mode = 'ServicePrincipal'
    ClientId = '11111111-1111-1111-1111-111111111111'
    CertificatePath = 'C:\secure\powerbi-inventory-spn.pem'
    ClientSecretEnvironmentVariable = 'POWERBI_CLIENT_SECRET'
}
```

The service principal needs:

1. An Entra app registration and service principal in the target tenant.
2. Inclusion in the security group allowed by the Power BI/Fabric tenant settings for service-principal API access.
3. The tenant setting that permits service principals to use read-only Power BI admin APIs.
4. Admin metadata-scanning tenant settings if schema, datasource, lineage, or expression metadata is required.
5. Write access to the in-scope workspaces or semantic models for per-model refresh-history retrieval.

Follow Microsoft's Power BI admin API guidance when configuring app permissions. For the read-only Admin APIs, don't add broad admin-consent-required Power BI application permissions unless another workload specifically requires them; access is controlled through the tenant settings and security-group allowlist.

#### Certificate authentication

Certificate authentication is preferred for scheduled operation. Set `CertificatePath` to a certificate file containing or referencing the private key accepted by Azure CLI, and leave the secret environment variable unset.

The certificate's public key must be uploaded to the app registration. Restrict filesystem access to the private-key file and establish a certificate-expiration and rotation process.

#### Client-secret authentication

Leave `CertificatePath` empty and set the environment variable named by `ClientSecretEnvironmentVariable`:

```powershell
$env:POWERBI_CLIENT_SECRET = '<client-secret-value>'

pwsh .\scripts\Invoke-PowerBIEstateInventory.ps1 `
  -ConfigurationPath .\config\estate-config.psd1
```

Don't store the secret in the PSD1, source control, command history, or CSV files. The environment variable only needs to exist in the process running the script. For a scheduled task or pipeline, use its protected secret store to populate the variable.

### Authentication limitations

Tenant-level Admin API access and semantic-model refresh-history access use different authorization checks. An identity can successfully inventory workspaces through the Admin APIs but still receive access errors for individual refresh histories. Review `data-quality-exceptions.csv` to identify those models, then grant the executing identity the required workspace/model access or supplement the results with retained refresh-history exports.

## Configure

1. Copy `config\estate-config.example.psd1` to a local configuration file.
2. Set the tenant ID, authentication mode, capacity environment classification, output path, and sizing assumptions.
3. For capacities without a naming convention, add exact mappings directly under `CapacityEnvironmentClassification.ExactMappings` or use the CSV mapping file.

Exact mappings take precedence over regex rules. A capacity can be mapped by:

- `CapacityId` — recommended when names aren't unique or might change.
- `CapacityName` — matched case-insensitively.

The mapping CSV supports `CapacityId,CapacityName,Environment`; each row needs either an ID or a name. Set `RequireAllCapacitiesClassified = $true` to stop collection when any capacity remains unclassified.

## Run

```powershell
pwsh .\scripts\Invoke-PowerBIEstateInventory.ps1 `
  -ConfigurationPath .\config\estate-config.psd1
```

`-CapacityEnvironmentMapPath` can still override the mapping-file path configured in the PSD1.

## Historical collection

The initial inventory performs a real historical lookup:

- `HistoricalCollection.RefreshHistoryApi` requests the available refresh-history entries for every semantic model and filters them to the configured lookback period.
- The API is entry-based rather than a guaranteed time archive. Microsoft documents a default of the last 60 available entries when `$top` isn't supplied; this tool supplies `MaximumEntriesPerModel`.
- `HistoricalCollection.ActivityLog` retrieves up to the service limit of four weeks.
- `ImportedRefreshHistoryPaths` can merge older retained exports into the same analysis. Imported files must use the generated `refresh-history.csv` columns, including `WorkspaceId`, `SemanticModelId`, and `StartTimeUtc`.

Forward observation is only needed when the service APIs and retained exports don't provide the full requested 90-day window. The collection manifest reports the earliest and latest refresh timestamps actually retrieved.

Run the observation collector daily to build a retained 90-day history:

```powershell
pwsh .\scripts\Invoke-PowerBIObservationCollection.ps1 `
  -ConfigurationPath .\config\estate-config.psd1
```

Export capacity utilization from the Fabric Capacity Metrics app with these minimum columns:

```text
CapacityId,CapacityName,P95UtilizationPercent,PeakUtilizationPercent,InteractiveDelayCount,BackgroundRejectionCount
```

Then generate gateway and capacity recommendations:

```powershell
pwsh .\scripts\New-VNetGatewaySizingRecommendation.ps1 `
  -ConfigurationPath .\config\estate-config.psd1 `
  -CapacityUtilizationPath .\input\capacity-utilization.csv
```

If no utilization file is provided, the sizing script writes `capacity-utilization-baseline-template.csv` and marks capacity decisions as requiring more evidence.

## Important sizing behavior

- Each VNet gateway member is modeled with 6 refresh slots, 15 DirectQuery slots, fixed 2-core/8-GB hardware, and 4 CUs of uptime consumption while active.
- Adding members improves aggregate concurrency and availability. It does not divide one large query across members.
- Capacity scenarios include fixed member uptime and a configurable sensitivity range for model-attributed VNet gateway/M Engine consumption.
- Capacity actions compare no change, scaling an existing capacity, and purchasing a dedicated capacity.
- The generated recommendation is an initial decision aid. Representative large models and the final topology must be piloted, then checked in the Fabric Capacity Metrics app before procurement.

## Outputs

The output folder contains tenant inventory, refresh history, activity events, exceptions, concurrency, detected pipeline batches, gateway topology/member recommendations, capacity actions, and a collection manifest. CSV files are formatted for direct use in Excel or Power BI.

## Tests

```powershell
Invoke-Pester .\tests
```
