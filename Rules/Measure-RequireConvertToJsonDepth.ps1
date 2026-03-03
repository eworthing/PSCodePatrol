function Measure-RequireConvertToJsonDepth {
    <#
    .SYNOPSIS
        Flags ConvertTo-Json calls that omit the -Depth parameter.

    .DESCRIPTION
        ConvertTo-Json has a default serialization depth of 2. Any object nested
        deeper than 2 levels is silently replaced with its .ToString() value
        (e.g., "@{Key=Value}") rather than being serialized — producing corrupt
        JSON output with no error or warning.

        This is a common mistake in LLM-generated code and in scripts that evolve
        from simple to deeply nested data models without updating serialization calls.

        Fix: always supply an explicit -Depth value appropriate for your data:
            $obj | ConvertTo-Json -Depth 10
            ConvertTo-Json -InputObject $obj -Depth 5 -Compress

        If your data is genuinely shallow (2 levels max), add -Depth 2 explicitly
        to document the assumption and silence this rule.

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition '$obj | ConvertTo-Json' `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-RequireConvertToJsonDepth'

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

        $ruleName = 'Measure-RequireConvertToJsonDepth'
        $results  = [System.Collections.Generic.List[object]]::new()

        $commandAsts = $ScriptBlockAst.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        foreach ($cmdAst in $commandAsts) {
            if ($cmdAst.CommandElements.Count -lt 1) { continue }

            # Match ConvertTo-Json or module-qualified form (e.g. Microsoft.PowerShell.Utility\ConvertTo-Json).
            $cmdName = $cmdAst.CommandElements[0].Extent.Text
            if ($cmdName -notmatch '(?i)(^|\\)ConvertTo-Json$') { continue }

            # Check whether any parameter is -Depth or an unambiguous prefix of it.
            # 'Depth'.StartsWith($pName) matches Depth/Dept/Dep/De but not Debug.
            # Length >= 2 prevents single-char '-D' from matching.
            $hasDepth = $false
            foreach ($el in $cmdAst.CommandElements) {
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $pName = $el.ParameterName
                if ('Depth'.StartsWith($pName, [System.StringComparison]::OrdinalIgnoreCase) -and $pName.Length -ge 2) {
                    $hasDepth = $true
                    break
                }
            }
            if ($hasDepth) { continue }

            $cmdExtent = $cmdAst.CommandElements[0].Extent
            $fixParams = @{
                StartLine       = $cmdExtent.StartLineNumber
                EndLine         = $cmdExtent.EndLineNumber
                StartColumn     = $cmdExtent.StartColumnNumber
                EndColumn       = $cmdExtent.EndColumnNumber
                ReplacementText = "$cmdName -Depth 10"
                FilePath        = $cmdExtent.File
                Description     = 'Add -Depth 10 to ConvertTo-Json.'
            }
            $fix = New-CorrectionExtent @fixParams

            $msg = "ConvertTo-Json without -Depth silently truncates — the default depth is 2." +
                " Add -Depth <n> (e.g., -Depth 10) to prevent silent data loss. Autofix adds -Depth 10."

            $results.Add((New-Diagnostic -Message $msg -Extent $cmdExtent -Severity 'Warning' -RuleName $ruleName -SuggestedCorrections @($fix)))
        }

        return $results.ToArray()
    }
}
