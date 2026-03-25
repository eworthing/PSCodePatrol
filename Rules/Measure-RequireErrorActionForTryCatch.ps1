function Measure-RequireErrorActionForTryCatch {
    <#
    .SYNOPSIS
        Flags cmdlet calls inside try/catch blocks that lack -ErrorAction Stop.

    .DESCRIPTION
        PowerShell cmdlets produce non-terminating errors by default. Non-terminating
        errors do NOT trigger catch blocks — the error goes to the error stream and
        execution continues inside the try block as if nothing happened.

        This is PowerShell's most counter-intuitive behavior for developers from any
        other language, where try/catch unconditionally catches errors. LLM coding
        agents and newcomers assume try { X } catch { Y } means Y runs when X fails,
        but in PowerShell this is only true for terminating errors.

        Fix: add -ErrorAction Stop to each cmdlet call inside the try block:
            try {
                Get-Item $path -ErrorAction Stop
            } catch {
                Write-Error "Failed: $_"
            }

        Or set the preference variable before the try:
            $ErrorActionPreference = 'Stop'
            try { Get-Item $path } catch { Write-Error "Failed: $_" }

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition 'try { Get-Item C:\test } catch { }' `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-RequireErrorActionForTryCatch'

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

        $ruleName = 'Measure-RequireErrorActionForTryCatch'
        $results = [System.Collections.Generic.List[object]]::new()

        # ── Helper: check if $ErrorActionPreference = 'Stop' is set in the enclosing
        #    scope before the try statement. ──
        function Test-ErrorActionPreferenceStop {
            param(
                [System.Management.Automation.Language.TryStatementAst]$TryAst
            )

            $tryStart = $TryAst.Extent.StartOffset

            # Walk up to find the nearest enclosing ScriptBlockAst.
            $scope = $TryAst.Parent
            while ($null -ne $scope -and $scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
                $scope = $scope.Parent
            }
            if ($null -eq $scope) { return $false }

            # Find all assignments to $ErrorActionPreference in this scope that
            # appear before the try statement.
            $assigns = @($scope.FindAll({
                        param($a)
                        if ($a -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
                        if ($a.Extent.EndOffset -ge $tryStart) { return $false }
                        if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
                        return ($a.Left.VariablePath.UserPath -eq 'ErrorActionPreference')
                    }, $true))

            if ($assigns.Count -eq 0) { return $false }

            # The last assignment before the try wins.
            $lastAssign = $assigns | Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1

            # Check if the RHS is the literal string 'Stop'.
            $rhs = $lastAssign.Right
            if ($rhs -is [System.Management.Automation.Language.PipelineAst]) {
                $elements = @($rhs.PipelineElements)
                if ($elements.Count -eq 1 -and
                    $elements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $rhs = $elements[0]
                }
            }
            if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $expr = $rhs.Expression
                if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $expr.Value -eq 'Stop') {
                    return $true
                }
            }

            return $false
        }

        # ── Helper: check if a CommandAst is directly in the try body (not inside
        #    a nested function or a nested try/catch). ──
        function Test-IsDirectlyInTryBody {
            param(
                [System.Management.Automation.Language.CommandAst]$CommandAst,
                [System.Management.Automation.Language.TryStatementAst]$TryAst
            )

            $current = $CommandAst.Parent
            while ($null -ne $current -and $current -ne $TryAst.Body) {
                # Nested function — different scope.
                if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    return $false
                }
                # Nested try with catch clauses — handled by the inner try.
                if ($current -is [System.Management.Automation.Language.TryStatementAst] -and
                    $current.CatchClauses.Count -gt 0) {
                    return $false
                }
                $current = $current.Parent
            }
            return ($null -ne $current)
        }

        # ── Helper: check if a CommandAst has -ErrorAction (or -EA or an unambiguous
        #    prefix with length >= 2) among its parameters. ──
        function Test-HasErrorAction {
            param(
                [System.Management.Automation.Language.CommandAst]$CommandAst
            )

            foreach ($el in $CommandAst.CommandElements) {
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $pName = $el.ParameterName

                # Exact match for the -EA alias.
                if ($pName -eq 'EA') { return $true }

                # Unambiguous prefix of 'ErrorAction' with length >= 2.
                if ($pName.Length -ge 2 -and
                    'ErrorAction'.StartsWith($pName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
            return $false
        }

        # ── Find all try/catch blocks ──
        $tryAsts = @($ScriptBlockAst.FindAll({
                    param($a)
                    $a -is [System.Management.Automation.Language.TryStatementAst] -and
                    $a.CatchClauses.Count -gt 0
                }, $true))

        foreach ($tryAst in $tryAsts) {
            # If $ErrorActionPreference = 'Stop' is set before this try, skip it.
            if (Test-ErrorActionPreferenceStop -TryAst $tryAst) { continue }

            # Find all command invocations in the try body.
            $commands = @($tryAst.Body.FindAll({
                        param($a)
                        $a -is [System.Management.Automation.Language.CommandAst]
                    }, $true))

            foreach ($cmdAst in $commands) {
                # Only process commands directly in this try body (not nested scopes).
                if (-not (Test-IsDirectlyInTryBody -CommandAst $cmdAst -TryAst $tryAst)) { continue }

                # The first element must be a named command (skip . or & invocations).
                if ($cmdAst.CommandElements.Count -lt 1) { continue }
                $firstElement = $cmdAst.CommandElements[0]
                if ($firstElement -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    continue
                }

                # Skip if -ErrorAction is already present.
                if (Test-HasErrorAction -CommandAst $cmdAst) { continue }

                $cmdName = $firstElement.Value
                $cmdExtent = $cmdAst.Extent

                $fixParams = @{
                    StartLine       = $cmdExtent.StartLineNumber
                    EndLine         = $cmdExtent.EndLineNumber
                    StartColumn     = $cmdExtent.StartColumnNumber
                    EndColumn       = $cmdExtent.EndColumnNumber
                    ReplacementText = "$($cmdExtent.Text) -ErrorAction Stop"
                    FilePath        = $cmdExtent.File
                    Description     = "Add -ErrorAction Stop to '$cmdName' inside try/catch."
                }
                $fix = ConvertTo-CorrectionExtent @fixParams

                $msg = "Command '$cmdName' in a try/catch block does not have -ErrorAction Stop. " +
                'Without it, non-terminating errors bypass the catch block entirely. ' +
                'Add -ErrorAction Stop or set $ErrorActionPreference = ''Stop'' before the try.'

                $diagParams = @{
                    Message              = $msg
                    Extent               = $cmdExtent
                    Severity             = 'Warning'
                    RuleName             = $ruleName
                    SuggestedCorrections = @($fix)
                }
                $results.Add((ConvertTo-DiagnosticRecord @diagParams))
            }
        }

        return $results.ToArray()
    }
}
