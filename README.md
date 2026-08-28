# Power BI / Fabric Tenant Inventory

Read-only PowerShell tooling that inventories a Power BI/Fabric tenant into a single CSV of capacities, workspaces, and semantic models.

VNet gateway planning is a **separate, legacy workflow** in this repository. See [Gateway planning (legacy)](#gateway-planning-legacy).

Licensed under the [MIT License](LICENSE).

## What the inventory produces

One CSV, by default `output\powerbi-inventory.csv`, with exactly these columns:

```text
CapacityName,CapacityId,WorkspaceName,WorkspaceId,SemanticModelName,SemanticModelCreatedAt,TargetStorageMode
```

Behavior:

- Every tenant capacity is inventoried, including suspended and inactive capacities.
- Only active, non-personal workspaces are scanned.
- Workspaces with no capacity assignment are **excluded**, and the count is reported as a warning.
- If a workspace contains more than one semantic model with the same name (compared case-insensitively), only the **most recently created** one is kept. Identical names in different workspaces are all kept.
- `SemanticModelCreatedAt` is normalized to UTC ISO 8601.
- `TargetStorageMode` is reported exactly as the scanner API returns it (for example `Abf` or `PremiumFiles`). It is not translated into Import/DirectQuery/Dual.
- The CSV is written to a temporary file and moved into place only after the whole run succeeds, so a failed run never leaves a partial file or overwrites the last good one.

## Prerequisites

- PowerShell 7
- A Microsoft Entra service principal authorized for Power BI read-only admin APIs

No Azure CLI, no module installation, and no configuration file are required for the inventory.

### Service principal setup

1. Create (or reuse) an Entra app registration and note its Application (client) ID.
2. Confirm the app has **no** admin-consent-required Power BI application permissions. Authorization comes from the tenant setting below, not from API permissions.
3. Add the app to an Entra **security group**.
4. In the Fabric admin portal, under **Admin API settings**, enable:
   - **Service principals can access read-only admin APIs**
   - **Enhanced admin APIs for workspace and content scanning** — required for the workspace scanner endpoints
5. Set both settings to **Specific security groups** and add the group from step 3.

Workspace-level Member or Admin access is **not** sufficient. These are tenant-wide endpoints; the security-group allowlist is what grants access. If the service principal isn't authorized, the run fails immediately and lists the missing prerequisites.

## Credentials

The inventory needs a tenant ID, a client ID, and a client secret. Each is resolved from the first source that supplies it:

| Value | Resolution order |
|---|---|
| Tenant ID | `-TenantId` parameter → `POWERBI_TENANT_ID` process variable → `.env` |
| Client ID | `-ClientId` parameter → `POWERBI_CLIENT_ID` process variable → `.env` |
| Secret variable *name* | `-ClientSecretEnvironmentVariable` → `POWERBI_CLIENT_SECRET_VARIABLE` → `.env` → defaults to `POWERBI_CLIENT_SECRET` |
| Client secret | named process variable → `.env` → **Windows user-scoped variable** of the same name |

Only the *name* of the secret variable is ever passed on the command line or stored in `.env` — never the secret value itself.

Because the secret also falls back to the Windows user scope, a variable set through **System Properties → Environment Variables** works even in a shell that started before it was created.

### Option A: existing environment variables (no file)

```powershell
pwsh .\scripts\Invoke-FabricTenantInventory.ps1 `
  -TenantId  00000000-0000-0000-0000-000000000000 `
  -ClientId  11111111-1111-1111-1111-111111111111 `
  -ClientSecretEnvironmentVariable FABRIC_TEST_SP_SECRET
```

### Option B: a .env file

Copy `.env.example` to `.env` and fill it in. To keep the secret out of the file entirely, point `.env` at the variable that already holds it:

```text
POWERBI_TENANT_ID=00000000-0000-0000-0000-000000000000
POWERBI_CLIENT_ID=11111111-1111-1111-1111-111111111111
POWERBI_CLIENT_SECRET_VARIABLE=FABRIC_TEST_SP_SECRET
```

Then every run is just:

```powershell
pwsh .\scripts\Invoke-FabricTenantInventory.ps1
```

`.env` is gitignored. Never commit it, and keep it out of shared folders. In CI or a scheduled task, set the same variable names from the platform's protected secret store instead of shipping a `.env` file.

The secret is only ever sent in the encoded token request body. It is never logged, printed, written to the CSV, or included in an error message.

## Run

Verify access without scanning anything:

```powershell
pwsh .\scripts\Invoke-FabricTenantInventory.ps1 -TestConnectionOnly
```

Full inventory:

```powershell
pwsh .\scripts\Invoke-FabricTenantInventory.ps1
```

Useful parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-ClientSecretEnvironmentVariable` | `POWERBI_CLIENT_SECRET` | Name of the variable holding the secret |
| `-OutputPath` | `output\powerbi-inventory.csv` | Destination CSV |
| `-EnvironmentFilePath` | `.env` in the repo root | Alternate credential file |
| `-WorkspaceBatchSize` | `100` | Workspaces per scan request (API maximum is 100) |
| `-PollSeconds` | `2` | Scan status polling interval |
| `-TestConnectionOnly` | off | Check authorization and exit |

Add `-Verbose` to see per-batch scan progress on large tenants.

## Repeat runs

The command is safe to re-run at any time. It is read-only, takes no configuration file, and fully replaces the output CSV on success. To schedule it, point a task at the same command line and supply the three values from the scheduler's secret store.

Throttling limits worth knowing for large tenants: 200 capacity requests/hour, 500 scan requests/hour, and 100 workspaces per scan request. The client honors `Retry-After`, retries transient failures with jitter, and warns when a run needs an unusually large number of batches.

## Failure behavior

- Missing credentials fail before any API call, naming the variable that wasn't found.
- An authorization failure explains the tenant settings and security-group requirement.
- If any workspace scan batch fails — including when a workspace's capacity is unavailable — the run aborts, names the affected workspaces, and leaves the previous CSV untouched.
- If duplicate model names in one workspace can't be ordered because creation timestamps are missing or invalid, the run fails rather than guessing.

## Tests

```powershell
Invoke-Pester .\tests
```

## Gateway planning (legacy)

The VNet gateway sizing and capacity workflow is retained unchanged and is scheduled for its own refactor. It still uses the PSD1 configuration, Azure CLI authentication, and the environment classification model that the inventory no longer uses.

```powershell
pwsh .\scripts\Invoke-GatewayPlanningCollection.ps1 -ConfigurationPath .\config\estate-config.psd1
pwsh .\scripts\Invoke-PowerBIObservationCollection.ps1 -ConfigurationPath .\config\estate-config.psd1
pwsh .\scripts\New-VNetGatewaySizingRecommendation.ps1 -ConfigurationPath .\config\estate-config.psd1 -CapacityUtilizationPath .\input\capacity-utilization.csv
```

`Invoke-GatewayPlanningCollection.ps1` was previously named `Invoke-PowerBIEstateInventory.ps1`. It collects refresh history, activity events, and environment-classified estate data for gateway sizing. Use `Invoke-FabricTenantInventory.ps1` for inventory.

Gateway sizing notes:

- Each gateway member is modeled with 6 refresh slots, 15 DirectQuery slots, 2 cores/8 GB, and 4 CUs of uptime consumption while active.
- Adding members improves aggregate concurrency and availability; it does not split one large query across members.
- Recommendations are an initial decision aid. Pilot representative models and confirm in the Fabric Capacity Metrics app before procurement.
