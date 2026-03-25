#Requires -Modules Pester, PSScriptAnalyzer

<#
.SYNOPSIS
    Tests for the Measure-RequireErrorActionForTryCatch custom PSScriptAnalyzer rule.

.DESCRIPTION
    Validates that the rule detects cmdlet calls inside try/catch blocks that are
    missing -ErrorAction Stop (which causes non-terminating errors to bypass the
    catch block) and does NOT flag calls that already have -ErrorAction, that are
    protected by $ErrorActionPreference = 'Stop', or that appear in try/finally
    blocks without a catch clause.
#>

BeforeAll {
    $Script:ScriptRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:RulePath   = Join-Path $Script:ScriptRoot 'PSCodePatrol/PSCodePatrol.psm1'

    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_errorAction_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'","''")'
    IncludeRules   = @('Measure-RequireErrorActionForTryCatch')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
}

Describe 'Measure-RequireErrorActionForTryCatch' {

    # ── Should flag (missing -ErrorAction in try/catch) ──

    Context 'flags cmdlets missing -ErrorAction in try/catch' {

        It 'flags bare cmdlet in try/catch' {
            $script = @'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-RequireErrorActionForTryCatch'
            $r[0].Message | Should -BeLike '*Get-Item*'
        }

        It 'flags cmdlet assigned to variable without -ErrorAction' {
            $script = @'
try {
    $result = Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags multiple cmdlets in same try block' {
            $script = @'
try {
    Get-Item $path
    Set-Location $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags pipeline cmdlets in try block' {
            $script = @'
try {
    Get-ChildItem C:\ | Where-Object { $_.Length -gt 0 }
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags when $ErrorActionPreference is set to Continue before try' {
            $script = @'
$ErrorActionPreference = 'Continue'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags when $ErrorActionPreference is overridden from Stop to Continue' {
            $script = @'
$ErrorActionPreference = 'Stop'
$ErrorActionPreference = 'Continue'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags cmdlet in try block inside a function' {
            $script = @'
function Test-Func {
    try {
        Get-Item $path
    } catch {
        Write-Error $_
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── Should NOT flag (safe patterns) ──

    Context 'allows cmdlets with -ErrorAction or protected by preference variable' {

        It 'allows -ErrorAction Stop' {
            $script = @'
try {
    Get-Item $path -ErrorAction Stop
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -EA Stop (alias)' {
            $script = @'
try {
    Get-Item $path -EA Stop
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -ErrorAction Continue (any -ErrorAction value is intentional)' {
            $script = @'
try {
    Get-Item $path -ErrorAction Continue
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $ErrorActionPreference = Stop before try' {
            $script = @'
$ErrorActionPreference = 'Stop'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows try/finally without catch clause' {
            $script = @'
try {
    Get-Item $path
} finally {
    Write-Host "cleanup"
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -ErrorAction Stop with catch and finally' {
            $script = @'
try {
    Get-Item $path -ErrorAction Stop
} catch {
    Write-Error $_
} finally {
    Write-Host "cleanup"
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows -ErrorAction abbreviated prefix (-Er Stop)' {
            $script = @'
try {
    Get-Item $path -Er Stop
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── Edge cases ──

    Context 'edge cases' {

        It 'does not flag .NET method calls inside try/catch' {
            $script = @'
try {
    [System.IO.File]::ReadAllText($path)
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'does not flag commands inside nested function definitions' {
            $script = @'
try {
    function Inner-Func {
        Get-Item $path
    }
    Inner-Func -ErrorAction Stop
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            # Should not flag Get-Item inside Inner-Func (different scope).
            # Should flag Inner-Func call only if it lacks -ErrorAction.
            # Inner-Func has -ErrorAction Stop so it should not be flagged.
            $r.Count | Should -Be 0
        }

        It 'flags outer try but not inner try commands (nested try/catch)' {
            $script = @'
try {
    Get-ChildItem C:\
    try {
        Get-Item $path -ErrorAction Stop
    } catch {
        Write-Error $_
    }
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            # Only Get-ChildItem in the outer try should be flagged.
            $r.Count | Should -Be 1
            $r[0].Message | Should -BeLike '*Get-ChildItem*'
        }

        It 'flags splatted cmdlet call (known limitation — cannot inspect splat)' {
            $script = @'
try {
    Get-Item @params
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── SuggestedCorrections ──

    Context 'provides SuggestedCorrections' {

        It 'suggests adding -ErrorAction Stop' {
            $script = @'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $corrections = @($r[0].SuggestedCorrections)
            $corrections.Count | Should -Be 1
            $corrections[0].Text | Should -Be 'Get-Item $path -ErrorAction Stop'
        }
    }

    # ── Message content ──

    Context 'diagnostic message' {

        It 'message mentions the command name' {
            $script = @'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*Get-Item*'
        }

        It 'message mentions non-terminating errors' {
            $script = @'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*non-terminating*'
        }

        It 'severity is Warning' {
            $script = @'
try {
    Get-Item $path
} catch {
    Write-Error $_
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Severity | Should -Be 'Warning'
        }
    }
}
