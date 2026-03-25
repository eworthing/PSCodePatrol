#Requires -Modules Pester, PSScriptAnalyzer

<#
.SYNOPSIS
    Tests for the Measure-AvoidUnintentionalOutput custom PSScriptAnalyzer rule.

.DESCRIPTION
    Validates that the rule detects .NET method calls whose return values are not
    captured (polluting the output stream) and does NOT flag calls that are properly
    suppressed with [void], assigned to a variable, piped to Out-Null, or consumed
    as arguments.
#>

BeforeAll {
    $Script:ScriptRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:RulePath   = Join-Path $Script:ScriptRoot 'PSCodePatrol/PSCodePatrol.psm1'

    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_unintentionalOutput_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'","''")'
    IncludeRules   = @('Measure-AvoidUnintentionalOutput')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
}

Describe 'Measure-AvoidUnintentionalOutput' {

    # ── Should flag (uncaptured method calls) ──

    Context 'flags uncaptured method calls with known non-void return values' {

        It 'flags $list.Add("item")' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-AvoidUnintentionalOutput'
        }

        It 'flags $sb.Append("text")' {
            $script = @'
$sb = [System.Text.StringBuilder]::new()
$sb.Append("text")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $sb.AppendLine("text")' {
            $script = @'
$sb = [System.Text.StringBuilder]::new()
$sb.AppendLine("text")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $list.Remove("item")' {
            $script = @'
$list = [System.Collections.Generic.List[string]]::new()
$list.Remove("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $string.Replace("a", "b")' {
            $script = @'
$s = "hello"
$s.Replace("h", "j")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $dict.ContainsKey("k")' {
            $script = @'
$dict = @{}
$dict.ContainsKey("k")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags static method call [IO.Path]::GetHashCode()' {
            $script = '[IO.Path]::GetHashCode()'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $obj.GetType()' {
            $script = @'
$obj = "hello"
$obj.GetType()
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $obj.ToString()' {
            $script = @'
$obj = 42
$obj.ToString()
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags multiple uncaptured calls in same script' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("one")
$list.Add("two")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags case-insensitive method names' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags uncaptured call inside a function body' {
            $script = @'
function Test-Func {
    $list = [System.Collections.ArrayList]::new()
    $list.Add("item")
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── Should NOT flag (safe patterns) ──

    Context 'allows properly suppressed or consumed method calls' {

        It 'allows [void]$list.Add("item")' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
[void]$list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $null = $list.Add("item")' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$null = $list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $list.Add("item") | Out-Null' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("item") | Out-Null
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $index = $list.Add("item")' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$index = $list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows method call as cmdlet argument: Write-Host $sb.ToString()' {
            $script = @'
$sb = [System.Text.StringBuilder]::new("hello")
Write-Host $sb.ToString()
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $list.Clear() — void method not in blocklist' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Clear()
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $list.Sort() — void method not in blocklist' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Sort()
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $stream.Close() — not in blocklist' {
            $script = '$stream.Close()'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $stream.Flush() — not in blocklist' {
            $script = '$stream.Flush()'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows return $sb.ToString()' {
            $script = @'
function Get-Text {
    $sb = [System.Text.StringBuilder]::new("hello")
    return $sb.ToString()
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $list.Add("x") | ForEach-Object { $_ } — piped to command' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("x") | ForEach-Object { $_ }
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── Edge cases ──

    Context 'edge cases' {

        It 'flags outer Add but not inner ToString when used as argument' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add($obj.ToString())
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Message | Should -BeLike '*Add*'
        }

        It 'does not flag method call used in if-condition' {
            $script = @'
$dict = @{}
if ($dict.ContainsKey("k")) { "found" }
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'does not flag method call used in while-condition' {
            $script = @'
$reader = [System.IO.StreamReader]::new("test.txt")
while ($null -ne $reader.ReadLine()) { }
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── SuggestedCorrections ──

    Context 'provides SuggestedCorrections' {

        It 'suggests [void] prefix for $list.Add("item")' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '[void]$list.Add("item")'
        }

        It 'suggests [void] prefix for $sb.Append("text")' {
            $script = @'
$sb = [System.Text.StringBuilder]::new()
$sb.Append("text")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections[0].Text | Should -Be '[void]$sb.Append("text")'
        }
    }

    # ── Message content ──

    Context 'diagnostic message' {

        It 'message mentions the method name' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*.Add()*'
        }

        It 'message mentions output stream' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*output stream*'
        }

        It 'severity is Warning' {
            $script = @'
$list = [System.Collections.ArrayList]::new()
$list.Add("item")
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Severity | Should -Be 'Warning'
        }
    }
}
