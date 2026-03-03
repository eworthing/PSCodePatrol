function Measure-AvoidBacktickObfuscationNoOpInIdentifier {
    <#
    .SYNOPSIS
        Flags no-op/obfuscation backticks inside identifier-like tokens.

    .DESCRIPTION
        Scans Identifier, Generic, Parameter, and Variable tokens for backticks that
        precede a word character (regex: (?=[A-Za-z0-9_])). These backticks are no-ops
        — the following character is already literal — and are commonly used to visually
        obscure code (e.g., Ge`t-Chi`ldItem evades simple string matching).

        The lookahead (?=[A-Za-z0-9_]) is correct because backtick + word-char inside
        these token kinds is always a no-op escape. Backtick + non-word-char (like `n,
        `t, `$) would be a real escape sequence and is not matched.

        SuggestedCorrections are provided to remove the backtick character(s).

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition 'Ge`t-Chil`dItem' `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'

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

        $ruleName = 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
        $results  = [System.Collections.Generic.List[object]]::new()

        $text     = $ScriptBlockAst.Extent.Text
        $filePath = $ScriptBlockAst.Extent.File
        if ([string]::IsNullOrWhiteSpace($filePath)) { $filePath = '' }

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)

        $candidateKinds = @(
            [System.Management.Automation.Language.TokenKind]::Identifier,
            [System.Management.Automation.Language.TokenKind]::Generic,
            [System.Management.Automation.Language.TokenKind]::Parameter,
            [System.Management.Automation.Language.TokenKind]::Variable
        )

        foreach ($tok in ($tokens | Where-Object { $candidateKinds -contains $_.Kind })) {
            $t = $tok.Text
            if (-not $t -or ($t.IndexOf('`') -lt 0)) { continue }

            $backtickMatches = [regex]::Matches($t, "``(?=[A-Za-z0-9_])")
            if ($backtickMatches.Count -lt 1) { continue }

            $fixes = [System.Collections.Generic.List[object]]::new()
            foreach ($m in $backtickMatches) {
                # Skip known PowerShell escape sequences in bare-argument (Generic) tokens,
                # but only when the backtick is NOT embedded in an identifier-like word.
                # Escapes are case-sensitive: `n = newline, `N = literal N (no-op).
                if ($tok.Kind -eq [System.Management.Automation.Language.TokenKind]::Generic) {
                    $nextCharIdx = $m.Index + 1
                    $prevIsWord  = $m.Index -gt 0 -and $t[$m.Index - 1] -match '\w'
                    if (-not $prevIsWord -and
                        $nextCharIdx -lt $t.Length -and
                        @('0','a','b','e','f','n','r','t','v') -ccontains [string]$t[$nextCharIdx]) {
                        continue
                    }
                }

                $idx = $m.Index

                $fixParams = @{
                    StartLine       = $tok.Extent.StartLineNumber
                    EndLine         = $tok.Extent.StartLineNumber
                    StartColumn     = $tok.Extent.StartColumnNumber + $idx
                    EndColumn       = $tok.Extent.StartColumnNumber + $idx + 1
                    ReplacementText = ''
                    FilePath        = $filePath
                    Description     = 'Remove no-op backtick inside identifier-like token.'
                }
                $fixes.Add((New-CorrectionExtent @fixParams))
            }

            # All backtick matches were legitimate escape sequences — skip this token.
            if ($fixes.Count -eq 0) { continue }

            $msg = @(
                'CATEGORY: BacktickObfuscation.NoOpInIdentifier.',
                'ACTION: Remove the no-op backtick(s) inside the identifier/token.',
                'DETAIL: Backticks inside identifier-like tokens are visually misleading and commonly used for obfuscation.',
                'AUTOFIX: Yes (SuggestedCorrection removes the backtick character).'
            ) -join ' '

            $results.Add((New-Diagnostic -Message $msg -Extent $tok.Extent -Severity 'Warning' -RuleName $ruleName -SuggestedCorrections $fixes))
        }

        return $results.ToArray()
    }
}
