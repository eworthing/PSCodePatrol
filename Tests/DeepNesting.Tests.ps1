#Requires -Modules Pester, PSScriptAnalyzer

BeforeAll {
    $Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $Script:RulePath = Join-Path $Script:RepoRoot 'PSCodePatrol.psm1'

    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_deepnesting_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'", "''")'
    IncludeRules   = @('Measure-AvoidDeepNesting')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) {
        Remove-Item $Script:TempSettings -Force
    }
}

Describe 'Measure-AvoidDeepNesting' {
    It 'flags functions nested deeper than default threshold' {
        $script = @'
function TooDeep {
    if ($true) {
        if ($true) {
            if ($true) {
                if ($true) {
                    if ($true) {
                        "x"
                    }
                }
            }
        }
    }
}
'@

        $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
        $results.Count | Should -BeGreaterThan 0
        $results[0].RuleName | Should -Be 'Measure-AvoidDeepNesting'
        $results[0].Severity | Should -Be 'Warning'
    }

    It 'does not flag shallow nesting' {
        $script = @'
function Shallow {
    if ($true) {
        "x"
    }
}
'@

        $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
        $results.Count | Should -Be 0
    }
}
