#Requires -Modules Pester, PSScriptAnalyzer

<#
.SYNOPSIS
    Tests for the Measure-RequireConvertToJsonDepth custom PSScriptAnalyzer rule.

.DESCRIPTION
    Validates that the rule detects ConvertTo-Json calls that omit -Depth (which
    silently truncates objects nested deeper than 2 levels) and does NOT flag calls
    that already specify -Depth or an unambiguous prefix thereof.
#>

BeforeAll {
    $Script:ScriptRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:RulePath   = Join-Path $Script:ScriptRoot 'PSCodePatrol/PSCodePatrol.psm1'

    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_jsonDepth_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'","''")'
    IncludeRules   = @('Measure-RequireConvertToJsonDepth')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
}

Describe 'Measure-RequireConvertToJsonDepth' {

    # ── Should flag (missing -Depth) ──

    Context 'flags ConvertTo-Json without -Depth' {

        It 'flags bare ConvertTo-Json with no parameters' {
            $script = '$json = ConvertTo-Json $obj'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-RequireConvertToJsonDepth'
        }

        It 'flags piped ConvertTo-Json with no parameters' {
            $script = '$json = $obj | ConvertTo-Json'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags ConvertTo-Json -Compress without -Depth' {
            $script = '$json = $obj | ConvertTo-Json -Compress'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags ConvertTo-Json -InputObject without -Depth' {
            $script = '$json = ConvertTo-Json -InputObject $obj'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags multiple ConvertTo-Json calls in same script' {
            $script = @'
$a = $obj1 | ConvertTo-Json
$b = $obj2 | ConvertTo-Json
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags ConvertTo-Json inside a function' {
            $script = @'
function Export-Data {
    param($Data)
    $Data | ConvertTo-Json | Set-Content -Path 'out.json'
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags module-qualified ConvertTo-Json' {
            $script = '$json = Microsoft.PowerShell.Utility\ConvertTo-Json $obj'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── Should NOT flag (safe patterns) ──

    Context 'allows ConvertTo-Json with -Depth' {

        It 'allows -Depth with a value' {
            $script = '$json = $obj | ConvertTo-Json -Depth 10'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -Depth 2 (explicit shallow)' {
            $script = '$json = $obj | ConvertTo-Json -Depth 2'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -Depth with -Compress together' {
            $script = '$json = $obj | ConvertTo-Json -Depth 5 -Compress'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -Depth as prefix abbreviation (Dep)' {
            $script = '$json = $obj | ConvertTo-Json -Dep 10'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -Depth as prefix abbreviation (Dept)' {
            $script = '$json = $obj | ConvertTo-Json -Dept 10'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows ConvertFrom-Json (different cmdlet — not affected)' {
            $script = '$obj = $json | ConvertFrom-Json'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows ConvertTo-Csv (different cmdlet — not affected)' {
            $script = '$csv = $obj | ConvertTo-Csv'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -De 10 (two-char prefix passes StartsWith check)' {
            $script = '$json = $obj | ConvertTo-Json -De 10'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -Depth $variable (parameter detected regardless of value)' {
            $script = '$json = $obj | ConvertTo-Json -Depth $myDepth'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── Edge cases ──

    Context 'edge cases' {

        It 'flags -D 10 (single-char prefix filtered out by length >= 2 guard)' {
            $script = '$json = $obj | ConvertTo-Json -D 10'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags splatted ConvertTo-Json (known limitation — cannot inspect splat contents)' {
            $script = 'ConvertTo-Json @params'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── SuggestedCorrections ──

    Context 'provides SuggestedCorrections' {

        It 'suggests adding -Depth 10 after bare ConvertTo-Json' {
            $script = '$json = $obj | ConvertTo-Json'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be 'ConvertTo-Json -Depth 10'
        }

        It 'suggests adding -Depth 10 after module-qualified ConvertTo-Json' {
            $script = '$json = Microsoft.PowerShell.Utility\ConvertTo-Json $obj'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be 'Microsoft.PowerShell.Utility\ConvertTo-Json -Depth 10'
        }

        It 'suggests adding -Depth 10 when -Compress is present but -Depth is not' {
            $script = '$json = $obj | ConvertTo-Json -Compress'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be 'ConvertTo-Json -Depth 10'
        }
    }

    # ── Message content ──

    Context 'diagnostic message' {

        It 'message mentions default depth of 2' {
            $script = '$json = $obj | ConvertTo-Json'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*default depth is 2*'
        }

        It 'message mentions silent data corruption' {
            $script = '$json = $obj | ConvertTo-Json'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*silent*'
        }

        It 'severity is Warning' {
            $script = '$json = $obj | ConvertTo-Json'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Severity | Should -Be 'Warning'
        }
    }
}
