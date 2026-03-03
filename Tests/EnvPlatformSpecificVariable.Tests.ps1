#Requires -Modules Pester, PSScriptAnalyzer

<#
.SYNOPSIS
    Tests for the Measure-AvoidEnvPlatformSpecificVariable custom PSScriptAnalyzer rule.

.DESCRIPTION
    Validates that the rule detects Windows-only $env: variables that are unset on
    macOS/Linux. Variables with a clean drop-in replacement get autofix
    (SuggestedCorrections + Error severity); variables without a safe 1:1 swap get
    a warning only.
#>

BeforeAll {
    $Script:ScriptRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:RulePath   = Join-Path $Script:ScriptRoot 'PSCodePatrol/PSCodePatrol.psm1'

    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_envvars_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'","''")'
    IncludeRules   = @('Measure-AvoidEnvPlatformSpecificVariable')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
}

Describe 'Measure-AvoidEnvPlatformSpecificVariable' {

    # ── Should flag with autofix (Error severity) ──

    Context 'flags variables with autofix (Error)' {

        It 'flags $env:USERNAME' {
            $script = '$user = $env:USERNAME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-AvoidEnvPlatformSpecificVariable'
            $r[0].Severity | Should -Be 'Error'
        }

        It 'flags $env:COMPUTERNAME' {
            $script = '$host = $env:COMPUTERNAME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Error'
        }

        It 'flags $env:USERPROFILE' {
            $script = '$home = $env:USERPROFILE'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Error'
        }

        It 'flags $env:APPDATA' {
            $script = '$ad = $env:APPDATA'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Error'
        }

        It 'flags $env:LOCALAPPDATA' {
            $script = '$lad = $env:LOCALAPPDATA'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Error'
        }

        It 'flags $env:username (lowercase — case-insensitive)' {
            $script = '$u = $env:username'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $env:ComputerName (mixed case)' {
            $script = '$cn = $env:ComputerName'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags both USERNAME and COMPUTERNAME in the same script' {
            $script = @'
$user     = $env:USERNAME
$computer = $env:COMPUTERNAME
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags inside a function body' {
            $script = @'
function Get-Identity {
    [CmdletBinding()]
    param()
    process {
        "$env:USERNAME on $env:COMPUTERNAME"
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags inside an expandable string' {
            $script = @'
$msg = "Running as $env:USERNAME on $env:COMPUTERNAME"
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags inside a here-string' {
            $script = @'
$msg = @"
User: $env:USERNAME
"@
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── Should flag without autofix (Warning severity) ──

    Context 'flags variables without autofix (Warning)' {

        It 'flags $env:TEMP as Warning with no SuggestedCorrections' {
            $script = '$t = $env:TEMP'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Warning'
            $r[0].SuggestedCorrections | Should -BeNullOrEmpty
        }

        It 'flags $env:TMP as Warning' {
            $script = '$t = $env:TMP'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Warning'
        }

        It 'flags $env:HOMEDRIVE as Warning' {
            $script = '$d = $env:HOMEDRIVE'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Warning'
        }

        It 'flags $env:HOMEPATH as Warning' {
            $script = '$p = $env:HOMEPATH'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Severity | Should -Be 'Warning'
        }

        It 'message suggests alternative for $env:TEMP' {
            $script = '$t = $env:TEMP'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*GetTempPath*'
        }

        It 'message suggests $HOME for $env:HOMEDRIVE' {
            $script = '$d = $env:HOMEDRIVE'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*$HOME*'
        }
    }

    # ── Should NOT flag (safe patterns) ──

    Context 'allows safe env variable usage' {

        It 'allows $env:PATH' {
            $script = '$p = $env:PATH'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $env:USER (the macOS/Linux equivalent)' {
            $script = '$u = $env:USER'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $env:HOME' {
            $script = '$h = $env:HOME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows [Environment]::UserName (the recommended replacement)' {
            $script = '$u = [Environment]::UserName'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows [Environment]::MachineName (the recommended replacement)' {
            $script = '$m = [Environment]::MachineName'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $HOME (the recommended replacement for USERPROFILE)' {
            $script = '$h = $HOME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── SuggestedCorrections ──

    Context 'provides SuggestedCorrections' {

        It 'suggests [Environment]::UserName for $env:USERNAME at statement level' {
            $script = '$u = $env:USERNAME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '[Environment]::UserName'
        }

        It 'suggests [Environment]::MachineName for $env:COMPUTERNAME at statement level' {
            $script = '$m = $env:COMPUTERNAME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '[Environment]::MachineName'
        }

        It 'suggests $HOME for $env:USERPROFILE at statement level' {
            $script = '$h = $env:USERPROFILE'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '$HOME'
        }

        It 'suggests GetFolderPath for $env:APPDATA at statement level' {
            $script = '$a = $env:APPDATA'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be "[Environment]::GetFolderPath('ApplicationData')"
        }

        It 'suggests GetFolderPath for $env:LOCALAPPDATA at statement level' {
            $script = '$a = $env:LOCALAPPDATA'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be "[Environment]::GetFolderPath('LocalApplicationData')"
        }

        It 'wraps expression with $() inside expandable string' {
            $script = '"Hello $env:USERNAME"'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '$([Environment]::UserName)'
        }

        It 'wraps expression with $() inside expandable here-string' {
            $script = @'
@"
User: $env:USERNAME
"@
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '$([Environment]::UserName)'
        }

        It 'does NOT wrap $HOME with $() inside expandable string (variable, not expression)' {
            $script = '"Home is $env:USERPROFILE"'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '$HOME'
        }

        It 'wraps GetFolderPath with $() inside expandable string' {
            $script = '"AppData is $env:APPDATA"'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '$([Environment]::GetFolderPath(''ApplicationData''))'
        }

        It 'does not double-wrap inside sub-expression $($env:USERNAME)' {
            $script = '"Hello $($env:USERNAME)"'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            # Inside $(), parent is CommandExpressionAst, not ExpandableStringExpressionAst
            $corrections[0].Text | Should -Be '[Environment]::UserName'
        }

        It 'detects braced syntax ${env:USERNAME}' {
            $script = '$u = ${env:USERNAME}'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be '[Environment]::UserName'
        }
    }

    # ── Message content ──

    Context 'diagnostic message' {

        It 'autofix message mentions macOS/Linux' {
            $script = '$u = $env:USERNAME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*macOS*'
        }

        It 'autofix message mentions the replacement' {
            $script = '$u = $env:USERNAME'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*Environment*::UserName*'
        }

        It 'warn-only message mentions macOS/Linux' {
            $script = '$t = $env:TEMP'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*macOS*'
        }

        It 'warn-only message says No autofix' {
            $script = '$t = $env:TEMP'
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*No autofix*'
        }
    }
}
