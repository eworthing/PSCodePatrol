@{
    RootModule           = 'PSCodePatrol.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a3b8f7e2-4c1d-4e9a-b5f6-8d2e1c3a7b90'
    Author               = 'PSCodePatrol Contributors'
    Description          = 'Custom PSScriptAnalyzer rules for PowerShell code quality, PS 5.1 compatibility, and anti-obfuscation.'
    PowerShellVersion    = '5.1'
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
    VariablesToExport  = @()
    AliasesToExport    = @()
}
