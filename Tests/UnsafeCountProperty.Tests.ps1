#Requires -Modules Pester, PSScriptAnalyzer

<#
.SYNOPSIS
    Tests for the Measure-UnsafeCountProperty custom PSScriptAnalyzer rule.

.DESCRIPTION
    Validates that the rule detects .Count on variables assigned from commands/pipelines
    without @() wrapping (unsafe on PowerShell 5.1) and does NOT flag safe patterns.
#>

BeforeAll {
    $Script:ScriptRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:RulePath = Join-Path $Script:ScriptRoot 'PSCodePatrol/PSCodePatrol.psm1'

    # Write a temp settings file that loads only our rule (avoids auto-detect of
    # the project PSScriptAnalyzerSettings.psd1, which would double-load the module).
    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_test_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'","''")'
    IncludeRules   = @('Measure-UnsafeCountProperty')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
}

Describe 'Measure-UnsafeCountProperty' {

    # ── Should flag (unsafe patterns) ──

    Context 'flags unsafe .Count accesses' {

        It 'flags .Count on variable assigned from command without @()' {
            $script = @'
function Test-Fn {
    $items = Get-ChildItem
    $items.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
            $results[0].RuleName | Should -Be 'Measure-UnsafeCountProperty'
            $results[0].Line | Should -Be 3
        }

        It 'flags .Count on variable assigned from pipeline without @()' {
            $script = @'
function Test-Fn {
    $filtered = $items | Where-Object { $_.Active }
    $filtered.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
            $results[0].Line | Should -Be 3
        }

        It 'flags (command).Count — parenthesized without @()' {
            $script = @'
function Test-Fn {
    $x = (Import-Csv $path).Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*replace () with @()*'
        }

        It 'flags multiple variables independently' {
            $script = @'
function Test-Fn {
    $a = Get-Item x
    $b = Get-Item y
    $a.Count + $b.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 2
        }

        It 'flags Script:-scoped variables' {
            $script = @'
function Test-Fn {
    $Script:Items = Get-ChildItem
    $Script:Items.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
        }

        It 'flags .Count in top-level code (outside functions)' {
            $script = @'
$data = Import-Csv $path
$data.Count
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
        }

        It 'flags .Count inside string sub-expressions' {
            $script = @'
function Test-Fn {
    $items = Get-ChildItem
    Write-Host "Found $($items.Count) items"
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
        }

        It 'flags .Count used in comparisons' {
            $script = @'
function Test-Fn {
    $results = Get-Process
    if ($results.Count -gt 0) { }
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
        }
    }

    # ── Should NOT flag (safe patterns) ──

    Context 'allows safe .Count accesses' {

        It 'allows .Count when assignment uses @() wrapping' {
            $script = @'
function Test-Fn {
    $items = @(Get-ChildItem)
    $items.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows @($var).Count at point of use' {
            $script = @'
function Test-Fn {
    $items = Get-ChildItem
    @($items).Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows .Count on @() wrapped pipeline' {
            $script = @'
function Test-Fn {
    $sorted = @($data | Sort-Object Name)
    $sorted.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows @(command).Count inline' {
            $script = @'
function Test-Fn {
    $x = @(Import-Csv $path).Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows .Count on hashtable' {
            $script = @'
function Test-Fn {
    $hash = @{ a = 1; b = 2 }
    $hash.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows .Count on typed collection constructor' {
            $script = @'
function Test-Fn {
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows .Count on literal/variable assignment (non-command)' {
            $script = @'
function Test-Fn {
    $x = 5
    $x.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows .Count on += accumulator pattern' {
            $script = @'
function Test-Fn {
    $arr = @()
    $arr += Get-ChildItem
    $arr.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }

        It 'allows .Count on -split result (always returns string[])' {
            $script = @'
function Test-Fn {
    $parts = $str -split ','
    $parts.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 0
        }
    }

    # ── SuggestedCorrections ──

    Context 'provides SuggestedCorrections' {

        It 'suggests @($var).Count for variable access' {
            $script = @'
function Test-Fn {
    $results = Get-Process
    $results.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
            $corrections = @($results[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '@($results).Count'
        }

        It 'suggests @(command).Count for parenthesized command' {
            $script = @'
function Test-Fn {
    $x = (Get-ChildItem).Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
            $corrections = @($results[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '@(Get-ChildItem).Count'
        }
    }

    # ── Scope isolation ──

    Context 'scopes analysis per function' {

        It 'does not cross-contaminate between functions' {
            $script = @'
function Safe-Fn {
    $items = @(Get-ChildItem)
    $items.Count
}
function Unsafe-Fn {
    $other = Get-Process
    $other.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*other*'
        }
    }

    # ── Re-assignment ──

    Context 'handles variable re-assignment' {

        It 'flags .Count before safe re-assignment but not after' {
            $script = @'
function Test-Fn {
    $items = $data | Where-Object { $_.Active }
    Write-Verbose "$($items.Count) before filter"
    $items = @($items | Where-Object { $_.Enabled })
    $items.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            # Line 3 is before the @() re-assignment → should flag
            # Line 5 is after  the @() re-assignment → should not flag
            $results.Count | Should -Be 1
            $results[0].Line | Should -Be 3
        }

        It 'flags .Count after unsafe re-assignment overwrites safe one' {
            $script = @'
function Test-Fn {
    $items = @(Get-ChildItem)
    $items = Get-Process
    $items.Count
}
'@
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $results.Count | Should -Be 1
        }
    }
}
