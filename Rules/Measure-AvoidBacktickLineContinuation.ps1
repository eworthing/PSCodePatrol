function Measure-AvoidBacktickLineContinuation {
    <#
    .SYNOPSIS
        Disallow backtick (`) line continuation.

    .DESCRIPTION
        Flags TokenKind.LineContinuation (backtick immediately followed by newline).
        The PowerShell tokenizer emits a specific LineContinuation token kind for this
        pattern, so no regex scanning is needed.

        Messages are structured for agent consumption:
          CATEGORY / POLICY / ACTION / REFACTOR_HINTS / AUTOFIX

        Redundant vs Structural classification:
        - For each LineContinuation token, remove only the backtick and re-parse.
          If the script still parses without errors, the backtick is redundant and
          a SuggestedCorrection safely removes just the backtick character.
        - If removing the backtick introduces parse errors (or baseline errors exist),
          the backtick is structural — the line break requires refactoring.

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition "Get-ChildItem ```n    -Recurse" `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-AvoidBacktickLineContinuation'

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

        $ruleName = 'Measure-AvoidBacktickLineContinuation'
        $results  = [System.Collections.Generic.List[object]]::new()

        $text     = $ScriptBlockAst.Extent.Text
        $filePath = $ScriptBlockAst.Extent.File
        if ([string]::IsNullOrWhiteSpace($filePath)) { $filePath = '' }

        $tokens = $null
        $parseErrorsBaseline = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrorsBaseline)
        $hasBaselineParseErrors = ($parseErrorsBaseline -and $parseErrorsBaseline.Count -gt 0)

        # Re-parse test: remove the backtick character and check whether the script
        # still parses cleanly. If it does, the continuation was redundant.
        function Test-RemoveBacktickKeepsParsing {
            param(
                [Parameter(Mandatory)]
                [System.Management.Automation.Language.Token]$LineContinuationToken,
                [bool]$BaselineHasParseErrors
            )

            if ($BaselineHasParseErrors) { return $false }

            $start = $LineContinuationToken.Extent.StartOffset
            if ($start -lt 0 -or $start -ge $text.Length) { return $false }

            # Remove ONLY the backtick at the start offset; keep the newline sequence that follows.
            $modified = $text.Remove($start, 1)

            $t2 = $null
            $e2 = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($modified, [ref]$t2, [ref]$e2)

            return (-not $e2 -or $e2.Count -eq 0)
        }

        $lineContinuationKind = [System.Management.Automation.Language.TokenKind]::LineContinuation
        foreach ($lc in ($tokens | Where-Object Kind -EQ $lineContinuationKind)) {
            $testParams = @{
                LineContinuationToken  = $lc
                BaselineHasParseErrors = $hasBaselineParseErrors
            }
            $isRedundant = Test-RemoveBacktickKeepsParsing @testParams

            if ($isRedundant) {
                # Drop only the leading backtick and keep newline text.
                $replacement = ($lc.Extent.Text -replace '^\`', '')

                $fixParams = @{
                    StartLine       = $lc.Extent.StartLineNumber
                    EndLine         = $lc.Extent.EndLineNumber
                    StartColumn     = $lc.Extent.StartColumnNumber
                    EndColumn       = $lc.Extent.EndColumnNumber
                    ReplacementText = $replacement
                    FilePath        = $filePath
                    Description     = 'Remove redundant backtick line continuation (newline already parses without it).'
                }
                $fix = ConvertTo-CorrectionExtent @fixParams

                $msg = @(
                    'CATEGORY: BacktickLineContinuation.Redundant.',
                    'POLICY: Do not use backtick (`) for line continuation.',
                    'ACTION: Remove the backtick; keep the newline.',
                    (
                        'REFACTOR_HINTS: If formatting still needs cleanup, break after |, after an operator, ' +
                        'after a comma, or after opening (, {, [; use splatting for long parameter lists; use ' +
                        'grouping constructs (), @(), @{}.'
                    ),
                    'AUTOFIX: Yes (SuggestedCorrection removes backtick only).'
                ) -join ' '

                $diagParams = @{
                    Message              = $msg
                    Extent               = $lc.Extent
                    Severity             = 'Warning'
                    RuleName             = $ruleName
                    SuggestedCorrections = @($fix)
                }
                $results.Add((ConvertTo-DiagnosticRecord @diagParams))
                continue
            }

            $msg = @(
                'CATEGORY: BacktickLineContinuation.Structural.',
                'POLICY: Do not use backtick (`) for line continuation.',
                'ACTION: Remove the backtick and refactor so the newline is legal without it.',
                (
                    'REFACTOR_HINTS: Move the line break to a natural breakpoint (after | / operators / ' +
                    'commas / opening (, {, [); use splatting ($p=@{...}; Cmdlet @p); use grouping constructs ' +
                    '(), @(), @{} to allow multiline expressions.'
                ),
                'AUTOFIX: No (requires refactor).'
            ) -join ' '

            $diagParams = @{
                Message  = $msg
                Extent   = $lc.Extent
                Severity = 'Warning'
                RuleName = $ruleName
            }
            $results.Add((ConvertTo-DiagnosticRecord @diagParams))
        }

        return $results.ToArray()
    }
}
