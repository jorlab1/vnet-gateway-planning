@{
    TenantId = '<tenant-guid>'
    Authentication = @{
        Mode = 'Interactive' # Interactive or ServicePrincipal
        ClientId = ''
        CertificatePath = ''
        ClientSecretEnvironmentVariable = 'POWERBI_CLIENT_SECRET'
    }
    CapacityEnvironmentClassification = @{
        # Exact mappings are checked before regex rules. Use CapacityId when names
        # aren't unique or could change.
        ExactMappings = @(
            @{ CapacityName = 'Blue Capacity'; Environment = 'Dev' }
            @{ CapacityName = 'Green Capacity'; Environment = 'QA' }
            @{ CapacityId = '00000000-0000-0000-0000-000000000000'; Environment = 'UAT' }
            @{ CapacityName = 'Primary Analytics'; Environment = 'Prod' }
        )
        # Optional CSV with CapacityId, CapacityName, and Environment columns.
        MappingFile = '' # For example: 'capacity-environment-map.csv', relative to this PSD1 file.
        Rules = @(
            @{ Environment = 'Prod'; Pattern = '(?i)(^|[-_ ])prod(uction)?($|[-_ ])' }
            @{ Environment = 'UAT'; Pattern = '(?i)(^|[-_ ])uat($|[-_ ])' }
            @{ Environment = 'QA'; Pattern = '(?i)(^|[-_ ])qa($|[-_ ])' }
            @{ Environment = 'Dev'; Pattern = '(?i)(^|[-_ ])dev(elopment)?($|[-_ ])' }
        )
        RequireAllCapacitiesClassified = $false
    }
    HistoricalCollection = @{
        RefreshHistoryApi = @{
            Enabled = $true
            LookbackDays = 90
            MaximumEntriesPerModel = 1000
        }
        ActivityLog = @{
            Enabled = $true
            # The Power BI activity log API only exposes up to four weeks.
            LookbackDays = 28
        }
        # Optional retained exports using the refresh-history.csv schema.
        # Paths are relative to this configuration file.
        ImportedRefreshHistoryPaths = @()
        ForwardObservation = @{
            Enabled = $true
            TargetDays = 90
        }
    }
    ReportingTimeZone = 'Central Standard Time'
    OutputPath = '.\output'
    Scanner = @{
        IncludeDatasetSchema = $true
        IncludeDatasetExpressions = $false
        IncludeDatasourceDetails = $true
        IncludeLineage = $true
        WorkspaceBatchSize = 100
        PollSeconds = 2
    }
    Sizing = @{
        RefreshSlotsPerMember = 6
        DirectQuerySlotsPerMember = 15
        MaximumMembersPerCluster = 9
        HeadroomPercent = 25
        Percentile = 95
        BatchWindowMinutes = 5
        ProdMinimumMembers = 2
        UatMinimumMembers = 1
        NonProdMinimumMembers = 1
        UatReleaseCritical = $false
        CapacityTargetUtilizationPercent = 80
        GatewayUptimeFraction = @{
            Low = 0.25
            Base = 0.50
            High = 1.00
        }
        GatewayQueryCuPerActiveMember = @{
            Low = 0
            Base = 2
            High = 4
        }
    }
}
