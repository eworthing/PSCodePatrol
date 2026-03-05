function Measure-AvoidEnvPlatformSpecificVariable {
    <#
    .SYNOPSIS
        Flags Windows-only $env: variables that are unset on macOS/Linux.

    .DESCRIPTION
        Several common Windows environment variables are not set on macOS and
        Linux. Scripts that rely on them return an empty string silently — no
        error, no warning — producing hard-to-diagnose cross-platform failures.

        Autofix (SuggestedCorrections) is provided where a drop-in replacement
        exists:
            $env:USERNAME      → [Environment]::UserName
            $env:COMPUTERNAME  → [Environment]::MachineName
            $env:USERPROFILE   → $HOME
            $env:APPDATA       → [Environment]::GetFolderPath('ApplicationData')
            $env:LOCALAPPDATA  → [Environment]::GetFolderPath('LocalApplicationData')

        Warn-only (no autofix) for variables with no clean drop-in:
            $env:TEMP / $env:TMP   — [IO.Path]::GetTempPath() adds a trailing
                                     separator, so it is not a safe 1:1 swap.
            $env:HOMEDRIVE         — drive letters are a Windows concept.
            $env:HOMEPATH          — typically paired with HOMEDRIVE; replacing
                                     one alone is not meaningful.

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition '$u = $env:USERNAME' `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-AvoidEnvPlatformSpecificVariable'

    .OUTPUTS
        Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]
        $ScriptBlockAst
    )

    process {
        # Only analyze from the file-level AST to avoid duplicate diagnostics.
        if ($null -ne $ScriptBlockAst.Parent) { return }

        $ruleName = 'Measure-AvoidEnvPlatformSpecificVariable'
        $results  = [System.Collections.Generic.List[object]]::new()

        $filePath = $ScriptBlockAst.Extent.File
        if ([string]::IsNullOrWhiteSpace($filePath)) { $filePath = '' }

        # Uses VariableExpressionAst.VariablePath.UserPath so that $env:USERNAME inside
        # expandable strings, here-strings, and sub-expressions is also detected.
        $varAsts = $ScriptBlockAst.FindAll({
                param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst]
            }, $true)

        foreach ($varAst in $varAsts) {
            $varPath  = $varAst.VariablePath
            $userPath = $varPath.UserPath
            if ($null -eq $userPath) { continue }

            $bannedEntry = $null
            switch ($userPath.ToLower()) {
                # ── Autofix entries (Replacement is the drop-in) ──
                'env:username' {
                    $bannedEntry = @{
                        Replacement = '[Environment]::UserName'
                        Suggestion  = '[Environment]::UserName'
                    }
                }
                'env:computername' {
                    $bannedEntry = @{
                        Replacement = '[Environment]::MachineName'
                        Suggestion  = '[Environment]::MachineName'
                    }
                }
                'env:userprofile' {
                    $bannedEntry = @{
                        Replacement = '$HOME'
                        Suggestion  = '$HOME'
                        IsVariable  = $true   # no $() wrapping needed in strings
                    }
                }
                'env:appdata' {
                    $bannedEntry = @{
                        Replacement = "[Environment]::GetFolderPath('ApplicationData')"
                        Suggestion  = "[Environment]::GetFolderPath('ApplicationData')"
                    }
                }
                'env:localappdata' {
                    $bannedEntry = @{
                        Replacement = "[Environment]::GetFolderPath('LocalApplicationData')"
                        Suggestion  = "[Environment]::GetFolderPath('LocalApplicationData')"
                    }
                }
                # ── Warn-only entries (Replacement is $null) ──
                'env:temp' {
                    $bannedEntry = @{
                        Replacement = $null
                        Suggestion  = '[IO.Path]::GetTempPath()'
                    }
                }
                'env:tmp' {
                    $bannedEntry = @{
                        Replacement = $null
                        Suggestion  = '[IO.Path]::GetTempPath()'
                    }
                }
                'env:homedrive' {
                    $bannedEntry = @{
                        Replacement = $null
                        Suggestion  = '$HOME'
                    }
                }
                'env:homepath' {
                    $bannedEntry = @{
                        Replacement = $null
                        Suggestion  = '$HOME'
                    }
                }
            }
            if ($null -eq $bannedEntry) { continue }
            $replacement  = $bannedEntry.Replacement
            $suggestion   = $bannedEntry.Suggestion
            $originalText = $varAst.Extent.Text

            if ($null -ne $replacement) {
                # When the variable is directly inside an expandable string ("...$env:USERNAME..."),
                # expression-based replacements must be wrapped in $() so the expression is evaluated
                # rather than emitted as literal text. Variable replacements like $HOME work natively.
                # Inside a sub-expression ($($env:USERNAME)), the parent is CommandExpressionAst,
                # so the wrap does NOT apply — avoiding double $().
                $inExpandableString =
                $varAst.Parent -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                $isVariable = $bannedEntry.ContainsKey('IsVariable') -and $bannedEntry.IsVariable
                if ($inExpandableString -and -not $isVariable) {
                    $replacement = "`$($replacement)"
                }

                $fixParams = @{
                    StartLine       = $varAst.Extent.StartLineNumber
                    EndLine         = $varAst.Extent.EndLineNumber
                    StartColumn     = $varAst.Extent.StartColumnNumber
                    EndColumn       = $varAst.Extent.EndColumnNumber
                    ReplacementText = $replacement
                    FilePath        = $filePath
                    Description     = "Replace $originalText with $replacement for cross-platform compatibility."
                }
                $fix = ConvertTo-CorrectionExtent @fixParams

                $msg = "$originalText is not set on macOS/Linux — replace with $replacement. Autofix available."
                $diagParams = @{
                    Message              = $msg
                    Extent               = $varAst.Extent
                    Severity             = 'Error'
                    RuleName             = $ruleName
                    SuggestedCorrections = @($fix)
                }
                $results.Add((ConvertTo-DiagnosticRecord @diagParams))
            }
            else {
                # Warn-only — no safe drop-in replacement exists.
                $msg = "$originalText is not set on macOS/Linux — consider $suggestion instead. No autofix."
                $diagParams = @{
                    Message  = $msg
                    Extent   = $varAst.Extent
                    Severity = 'Warning'
                    RuleName = $ruleName
                }
                $results.Add((ConvertTo-DiagnosticRecord @diagParams))
            }
        }

        return $results.ToArray()
    }
}
