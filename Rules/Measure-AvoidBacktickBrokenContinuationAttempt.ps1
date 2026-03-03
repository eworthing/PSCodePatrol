function Measure-AvoidBacktickBrokenContinuationAttempt {
    <#
    .SYNOPSIS
        Flags backtick + trailing whitespace + newline (broken continuation attempt).

    .DESCRIPTION
        Detects a backtick at end of line followed by whitespace and then newline:
        "`[ \t]+(\r?\n)". This is typically an attempted line continuation that does
        NOT work because trailing whitespace after the backtick breaks it.

        No distinct token kind exists for this pattern, so regex scanning against the
        full script text is necessary. The IsIgnoredOffset closure excludes matches
        that fall within string, comment, or here-string token spans.

        No SuggestedCorrections are provided (avoid any auto-edit behavior).

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        $code = "Get-ChildItem ``  `r`n    -Recurse"
        Invoke-ScriptAnalyzer -ScriptDefinition $code `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-AvoidBacktickBrokenContinuationAttempt'

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

        $ruleName = 'Measure-AvoidBacktickBrokenContinuationAttempt'
        $results  = [System.Collections.Generic.List[object]]::new()

        $text     = $ScriptBlockAst.Extent.Text
        $filePath = $ScriptBlockAst.Extent.File
        if ([string]::IsNullOrWhiteSpace($filePath)) { $filePath = '' }

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)

        # Ignore backticks that fall within string, comment, or here-string tokens.
        $ignoreTokens = $tokens | Where-Object {
            $_.Kind -in @(
                [System.Management.Automation.Language.TokenKind]::Comment,
                [System.Management.Automation.Language.TokenKind]::StringLiteral,
                [System.Management.Automation.Language.TokenKind]::StringExpandable,
                [System.Management.Automation.Language.TokenKind]::HereStringLiteral,
                [System.Management.Automation.Language.TokenKind]::HereStringExpandable
            )
        }

        # Closure over $ignoreTokens — must stay in process block.
        function IsIgnoredOffset {
            param([int]$Offset)
            foreach ($t in $ignoreTokens) {
                if ($Offset -ge $t.Extent.StartOffset -and $Offset -lt $t.Extent.EndOffset) { return $true }
            }
            return $false
        }

        $pattern = "``[ \t]+(\r?\n)"
        foreach ($m in [regex]::Matches($text, $pattern)) {
            if (IsIgnoredOffset -Offset $m.Index) { continue }

            # Create a precise extent pointing at the backtick character itself.
            $extent = New-ScriptExtentFromOffset -Text $text -Offset $m.Index -Length 1 -FilePath $filePath

            $msg = @(
                'CATEGORY: BacktickLineContinuation.BrokenAttempt.',
                'POLICY: Do not use backtick (`) for line continuation.',
                'DETAIL: Trailing whitespace after the backtick means this is NOT a valid continuation and can hide errors.',
                'ACTION: Remove the backtick and the trailing whitespace, then refactor using natural line breaks or splatting.',
                'REFACTOR_HINTS: Break after | / operators / commas / opening (, {, [; use splatting ($p=@{...}; Cmdlet @p); use grouping constructs (), @(), @{}.',
                'AUTOFIX: No (guidance only; avoid auto-edit).'
            ) -join ' '

            $results.Add((New-Diagnostic -Message $msg -Extent $extent -Severity 'Warning' -RuleName $ruleName))
        }

        return $results.ToArray()
    }
}
