function Measure-UnsafeCountProperty {
    <#
    .SYNOPSIS
        Detects .Count on variables that may fail on PowerShell 5.1.

    .DESCRIPTION
        In PowerShell 7+, every object has a .Count property — scalars return 1,
        $null returns 0. In PowerShell 5.1, only collections have .Count. Calling
        .Count on a single object or $null throws:

            The property 'Count' cannot be found on this object.

        This rule flags .Count accesses on variables assigned from cmdlet or pipeline
        output without @() wrapping, which can produce scalar values when exactly one
        result is returned.

        Fix: Wrap the assignment in @() to guarantee an array:
            $results = @(Get-ChildItem -Filter *.log)
            if ($results.Count -gt 0) { ... }

        Or wrap at point of use:
            if (@($results).Count -gt 0) { ... }

        Also flags inline (command).Count that should be @(command).Count.

    .EXAMPLE
        Measure-UnsafeCountProperty -ScriptBlockAst $ScriptBlockAst
    .INPUTS
        [System.Management.Automation.Language.ScriptBlockAst]
    .OUTPUTS
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]]
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
        # PSScriptAnalyzer calls this function once per ScriptBlockAst in the file.
        # Only analyze from the file-level AST to avoid duplicate diagnostics.
        if ($null -ne $ScriptBlockAst.Parent) { return }

        $ruleName = 'Measure-UnsafeCountProperty'
        $diagnostics = New-Object System.Collections.Generic.List[object]

        # ── Helper: does an AST subtree contain any CommandAst (cmdlet/function call)? ──
        function Test-HasCommand {
            param([System.Management.Automation.Language.Ast]$Ast)
            $found = @($Ast.FindAll({
                        param($A)
                        $A -is [System.Management.Automation.Language.CommandAst]
                    }, $true))
            return ($found.Count -gt 0)
        }

        # ── Helper: is assignment RHS an @()-wrapped expression? ──
        # Two AST shapes depending on context:
        #   Shape A: PipelineAst > CommandExpressionAst > ArrayExpressionAst
        #   Shape B: CommandExpressionAst > ArrayExpressionAst  (direct)
        function Test-IsArrayWrapped {
            param([System.Management.Automation.Language.StatementAst]$Rhs)
            if ($Rhs -is [System.Management.Automation.Language.PipelineAst]) {
                $elements = @($Rhs.PipelineElements)
                if ($elements.Count -eq 1 -and
                    $elements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                    $elements[0].Expression -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                    return $true
                }
            }
            if ($Rhs -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $Rhs.Expression -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                return $true
            }
            return $false
        }

        # ── Helper: does the RHS pipeline end with Group-Object -AsHashTable? ──
        # Group-Object -AsHashTable always returns [Hashtable], whose .Count is
        # a built-in property — safe on both PS 5.1 and 7+.
        function Test-HasGroupObjectAsHashTable {
            param([System.Management.Automation.Language.Ast]$Ast)
            $commands = @($Ast.FindAll({
                        param($A)
                        $A -is [System.Management.Automation.Language.CommandAst]
                    }, $true))
            foreach ($cmd in $commands) {
                $name = $cmd.GetCommandName()
                if ($name -eq 'Group-Object' -or $name -eq 'group') {
                    $hasSwitch = $cmd.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $_.ParameterName -eq 'AsHashTable'
                    }
                    if ($hasSwitch) { return $true }
                }
            }
            return $false
        }

        # ── Analyze a single scope (function body or top-level script) ──
        # Uses offset-ordered walk: assignments and .Count accesses are merged into a
        # single list sorted by source position, then processed top-to-bottom. This
        # tracks variable safety state at each point in the code so that:
        #   $var = Get-Foo;  $var.Count   → flags (unsafe at this point)
        #   $var = @(Get-Bar); $var.Count → does not flag (safe after re-assignment)
        #
        # -SearchNested $true  → recurse into nested ScriptBlockAst (use for functions)
        # -SearchNested $false → stay in current scope, skip function bodies (use for top-level)
        function Invoke-ScopeAnalysis {
            param(
                [System.Management.Automation.Language.Ast]$ScopeAst,
                [bool]$SearchNested = $true
            )

            # Collect all assignment statements
            $assignments = @($ScopeAst.FindAll({
                        param($A)
                        $A -is [System.Management.Automation.Language.AssignmentStatementAst]
                    }, $SearchNested))

            # Collect all .Count member accesses
            $countAccesses = @($ScopeAst.FindAll({
                        param($A)
                        if ($A -isnot [System.Management.Automation.Language.MemberExpressionAst]) { return $false }
                        if ($A.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            return $false
                        }
                        return ($A.Member.Value -eq 'Count')
                    }, $SearchNested))

            # Build a merged work list sorted by source offset
            $workList = New-Object System.Collections.Generic.List[PSCustomObject]
            foreach ($a in $assignments) {
                $workList.Add([PSCustomObject]@{ Kind = 'assign'; Node = $a; Offset = $a.Extent.StartOffset })
            }
            foreach ($c in $countAccesses) {
                $workList.Add([PSCustomObject]@{ Kind = 'count'; Node = $c; Offset = $c.Extent.StartOffset })
            }
            $sorted = @($workList | Sort-Object -Property Offset)

            # Walk in source order, tracking variable safety state
            $unsafeVars = New-Object 'System.Collections.Generic.HashSet[string]' @(
                [System.StringComparer]::OrdinalIgnoreCase
            )

            foreach ($item in $sorted) {
                if ($item.Kind -eq 'assign') {
                    $assign = $item.Node

                    # Only inspect plain = assignments (not +=, -=, etc.)
                    if ($assign.Operator -ne 'Equals') { continue }

                    # Extract variable name from LHS
                    $varName = $null
                    $lhs = $assign.Left
                    if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $varName = $lhs.VariablePath.UserPath
                    }
                    elseif ($lhs -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                        $lhs.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $varName = $lhs.Child.VariablePath.UserPath
                    }
                    if (-not $varName) { continue }

                    $rhs = $assign.Right

                    if (Test-IsArrayWrapped $rhs) {
                        # Safe: @() wrapping guarantees array
                        $unsafeVars.Remove($varName) | Out-Null
                    }
                    elseif (Test-HasGroupObjectAsHashTable $rhs) {
                        # Group-Object -AsHashTable returns [Hashtable]; .Count is always safe
                        $unsafeVars.Remove($varName) | Out-Null
                    }
                    elseif (Test-HasCommand $rhs) {
                        # Unsafe: command/pipeline without @()
                        $unsafeVars.Add($varName) | Out-Null
                    }
                    continue
                }

                # ── .Count access ──
                $access = $item.Node
                $expr = $access.Expression

                # Already wrapped: @($var).Count — safe on all versions
                if ($expr -is [System.Management.Automation.Language.ArrayExpressionAst]) { continue }

                # Case 1: $var.Count where $var is currently unsafe
                if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $varName = $expr.VariablePath.UserPath
                    if ($unsafeVars.Contains($varName)) {
                        $corrected = '@($' + $varName + ').Count'
                        $msg = (
                            'Variable ''${0}'' was assigned from a command/pipeline without @() wrapping. ' +
                            'On PowerShell 5.1, .Count fails on single objects and $null. ' +
                            'Fix: $' + '{0} = @(...) or use @(${0}).Count here.'
                        ) -f $varName

                        $extent = $access.Extent
                        $fixParams = @{
                            StartLine       = $extent.StartLineNumber
                            EndLine         = $extent.EndLineNumber
                            StartColumn     = $extent.StartColumnNumber
                            EndColumn       = $extent.EndColumnNumber
                            ReplacementText = $corrected
                            FilePath        = $extent.File
                            Description     = 'Wrap in @() to ensure .Count works on PS 5.1'
                        }
                        $fix = ConvertTo-CorrectionExtent @fixParams
                        $diagParams = @{
                            Message              = $msg
                            Extent               = $extent
                            Severity             = 'Warning'
                            RuleName             = $ruleName
                            SuggestedCorrections = @($fix)
                        }
                        $diagnostics.Add((ConvertTo-DiagnosticRecord @diagParams))
                    }
                    continue
                }

                # Case 2: (command).Count — parenthesized command without @()
                if ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
                    if (Test-HasCommand $expr) {
                        $inner = $expr.Extent.Text          # e.g. "(Get-Foo)"
                        $corrected = '@' + $inner + '.Count'
                        $msg = (
                            'Command result accessed with .Count inside () instead of @(). ' +
                            'On PowerShell 5.1, .Count fails on single objects. ' +
                            'Fix: replace () with @().'
                        )

                        $extent = $access.Extent
                        $fixParams = @{
                            StartLine       = $extent.StartLineNumber
                            EndLine         = $extent.EndLineNumber
                            StartColumn     = $extent.StartColumnNumber
                            EndColumn       = $extent.EndColumnNumber
                            ReplacementText = $corrected
                            FilePath        = $extent.File
                            Description     = 'Wrap in @() to ensure .Count works on PS 5.1'
                        }
                        $fix = ConvertTo-CorrectionExtent @fixParams
                        $diagParams = @{
                            Message              = $msg
                            Extent               = $extent
                            Severity             = 'Warning'
                            RuleName             = $ruleName
                            SuggestedCorrections = @($fix)
                        }
                        $diagnostics.Add((ConvertTo-DiagnosticRecord @diagParams))
                    }
                }
            }
        }

        # ── Analyze each function independently (per-function variable scope) ──
        $functions = @($ScriptBlockAst.FindAll({
                    param($A)
                    $A -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true))

        foreach ($fn in $functions) {
            Invoke-ScopeAnalysis -ScopeAst $fn.Body
        }

        # ── Analyze top-level code (outside functions) ──
        # SearchNested=$false skips ScriptBlockAst children (function bodies),
        # so this pass only covers assignments and .Count accesses at script scope.
        Invoke-ScopeAnalysis -ScopeAst $ScriptBlockAst -SearchNested $false

        return $diagnostics
    }
}
