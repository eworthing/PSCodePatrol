@{
    RootModule           = 'PSCodePatrol.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a3b8f7e2-4c1d-4e9a-b5f6-8d2e1c3a7b90'

    Author               = 'PSCodePatrol Contributors'
    CompanyName          = 'PSCodePatrol Contributors'
    Copyright            = 'Copyright (c) 2026 PSCodePatrol Contributors. MIT License.'
    Description          = 'Custom PSScriptAnalyzer rules for PowerShell code quality, PS 5.1 compatibility, and anti-obfuscation.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    RequiredModules = @(
        @{
            ModuleName    = 'PSScriptAnalyzer'
            ModuleVersion = '1.20.0'
        }
    )

    FunctionsToExport = @(
        'Measure-AvoidDeepNesting'
        'Measure-UnsafeCountProperty'
        'Measure-AvoidBacktickLineContinuation'
        'Measure-AvoidBacktickBrokenContinuationAttempt'
        'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
        'Measure-AvoidArrayAdditionInLoop'
        'Measure-AvoidEnvPlatformSpecificVariable'
        'Measure-RequireConvertToJsonDepth'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @(
                'PSScriptAnalyzer'
                'StaticAnalysis'
                'CodeQuality'
                'Security'
                'CrossPlatform'
                'PSEdition_Desktop'
                'PSEdition_Core'
                'Windows'
                'Linux'
                'MacOS'
            )
            ProjectUri   = 'https://github.com/eworthing/PSCodePatrol'
            LicenseUri   = 'https://github.com/eworthing/PSCodePatrol/blob/main/LICENSE'
            ReleaseNotes = 'See CHANGELOG.md in the project repository.'
        }
    }
}
