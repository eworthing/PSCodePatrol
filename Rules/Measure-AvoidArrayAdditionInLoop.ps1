function Measure-AvoidArrayAdditionInLoop {
    <#
    .SYNOPSIS
        Detects += and equivalent array/string accumulation inside loops.

    .DESCRIPTION
        PowerShell arrays and strings are immutable. Every += (or the equivalent
        $var = $var + $item) inside a loop allocates a new object and copies all
        existing elements, producing O(n^2) time and memory. With large collections
        this causes severe performance degradation — silently and with no error.

        Detected patterns:
          - $arr += $item   inside foreach/for/while/do-while/do-until
          - $arr += $item   inside ForEach-Object / % / foreach (pipeline alias)
          - $arr = $arr + $item   (equivalent form, either operand order)

        Safe patterns excluded (no diagnostic emitted):
          - $obj.Prop += 1   (member-access LHS — modifying a property, O(1))
          - $hash['k'] += 1  (indexer LHS — modifying a value, O(1))
          - $counter += 1    (numeric-constant RHS — integer addition, O(1))
          - $counter = $counter + 1  (same, equivalent form)

        Fix (arrays): collect loop output with @() to guarantee an array result:

            $result = @(foreach ($item in $collection) { Transform $item })

        The @() wrapper ensures $result is always an array — without it, 0 items
        returns $null and 1 item returns a scalar, breaking .Count and indexing.

        Alternative: use a generic List when you need Add/Remove/Insert:

            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $collection) {
                $list.Add($item)
            }

        Fix (strings): use StringBuilder instead of string +=:

            $sb = [System.Text.StringBuilder]::new()
            foreach ($item in $collection) { [void]$sb.Append($item) }
            $result = $sb.ToString()

        Known limitations:
          - .ForEach() method syntax is not detected (different AST node type).
          - ForEach-Object -Begin { $arr += ... } is flagged even though -Begin
            runs once; distinguishing positional/named parameters would add
            significant complexity for a rare edge case.

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition '$a=@(); foreach($x in $c){$a+=$x}' `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-AvoidArrayAdditionInLoop'

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

        $ruleName = 'Measure-AvoidArrayAdditionInLoop'
        $results  = [System.Collections.Generic.List[object]]::new()

        $loopTypes = @(
            [System.Management.Automation.Language.ForEachStatementAst],
            [System.Management.Automation.Language.ForStatementAst],
            [System.Management.Automation.Language.WhileStatementAst],
            [System.Management.Automation.Language.DoWhileStatementAst],
            [System.Management.Automation.Language.DoUntilStatementAst]
        )

        # Returns the enclosing ForEach-Object / % / foreach CommandAst when $SbAst
        # is the scriptblock argument to one of those cmdlets, or $null otherwise.
        function Get-ForEachObjectAncestor {
            param([System.Management.Automation.Language.ScriptBlockAst]$SbAst)
            $sbParent = $SbAst.Parent
            if ($sbParent -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $null }
            $cmdAst = $sbParent.Parent
            if ($cmdAst -isnot [System.Management.Automation.Language.CommandAst]) { return $null }
            if ($cmdAst.CommandElements.Count -lt 1) { return $null }
            $cmdName = $cmdAst.CommandElements[0].Extent.Text
            if ($cmdName -match '(?i)^(ForEach-Object|%|foreach)$') { return $cmdAst }
            return $null
        }

        # Walk up the parent chain to find a loop ancestor, stopping at function
        # definition boundaries to avoid false positives from nested function defs.
        # Also recognises ForEach-Object / % / foreach (pipeline alias) as a loop.
        function Get-LoopAncestor {
            param([System.Management.Automation.Language.Ast]$Ast)
            $current = $Ast.Parent
            while ($null -ne $current) {
                foreach ($loopType in $loopTypes) {
                    if ($current -is $loopType) { return $current }
                }
                if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    return $null
                }
                if ($current -is [System.Management.Automation.Language.ScriptBlockAst]) {
                    $feoAncestor = Get-ForEachObjectAncestor -SbAst $current
                    if ($null -ne $feoAncestor) { return $feoAncestor }
                }
                $current = $current.Parent
            }
            return $null
        }

        # Helper: build the diagnostic message for a flagged assignment.
        function New-ArrayLoopDiagnostic {
            param(
                [System.Management.Automation.Language.Ast]$AssignAst,
                [string]$LhsText
            )
            $msg = "'$LhsText += ...' in a loop is O(n^2) — arrays and strings are immutable so each += allocates a new copy." +
                " For arrays: collect output with `$var = @(foreach (...) { ... }) (the @() ensures an array even for 0 or 1 items)," +
                " or use [System.Collections.Generic.List[object]]::new() with .Add()." +
                " For strings: use [System.Text.StringBuilder]. No autofix."
            return (New-Diagnostic -Message $msg -Extent $AssignAst.Extent -Severity 'Warning' -RuleName $ruleName)
        }

        # Helper: returns $true when the RHS is a numeric constant (int/long/double/decimal).
        function Test-NumericConstantRhs {
            param([System.Management.Automation.Language.StatementAst]$RhsAst)
            if ($RhsAst -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $false }
            $inner = $RhsAst.Expression
            if ($inner -isnot [System.Management.Automation.Language.ConstantExpressionAst]) { return $false }
            $val = $inner.Value
            return ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal])
        }

        # Helper: returns $true when the assignment sits in the Iterator (step)
        # clause of a for-loop rather than the Body — e.g. for (...; ...; $i += $n).
        function Test-ForLoopIterator {
            param(
                [System.Management.Automation.Language.AssignmentStatementAst]$AssignAst,
                [System.Management.Automation.Language.Ast]$LoopAncestor
            )
            if ($LoopAncestor -isnot [System.Management.Automation.Language.ForStatementAst]) { return $false }
            $iter = $LoopAncestor.Iterator
            if ($null -eq $iter) { return $false }
            return ($AssignAst.Extent.StartOffset -ge $iter.Extent.StartOffset -and
                    $AssignAst.Extent.EndOffset   -le $iter.Extent.EndOffset)
        }

        # Helper: returns $true if an expression references the target variable path.
        function Test-ExprReferencesVariable {
            param(
                [System.Management.Automation.Language.Ast]$ExprAst,
                [string]$VariablePath
            )
            if ($null -eq $ExprAst) { return $false }
            $refs = $ExprAst.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $a.VariablePath.UserPath -eq $VariablePath
            }, $true)
            return (@($refs).Count -gt 0)
        }

        # Helper: skip one-shot in-loop string/array shaping when the variable was
        # explicitly reinitialised in the same loop body before the append.
        # Example:
        #   foreach (...) {
        #     $dtStr = $parts[$colDate]
        #     if ($hasTime) { $dtStr += ' ' + $parts[$colTime] }  # suppress
        #   }
        function Test-LoopLocalReinitializationBeforeAppend {
            param(
                [string]$VariablePath,
                [System.Management.Automation.Language.AssignmentStatementAst]$CurrentAssign,
                [System.Management.Automation.Language.Ast]$LoopAncestor
            )
            if ($null -eq $CurrentAssign -or $null -eq $LoopAncestor) { return $false }
            $currentStart = $CurrentAssign.Extent.StartOffset
            $loopStart = $LoopAncestor.Extent.StartOffset

            $priorAssigns = @($LoopAncestor.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $a.Left.VariablePath.UserPath -eq $VariablePath -and
                $a.Extent.StartOffset -gt $loopStart -and
                $a.Extent.EndOffset -lt $currentStart
            }, $true) | Sort-Object { $_.Extent.EndOffset })

            if ($priorAssigns.Count -eq 0) { return $false }

            $lastAssign = $priorAssigns[-1]
            $eqOp = [System.Management.Automation.Language.TokenKind]::Equals
            if ($lastAssign.Operator -ne $eqOp) { return $false }

            # If the initializer already references the same variable ($x = $x + ...),
            # that's still accumulation and should not be suppressed.
            if (Test-ExprReferencesVariable -ExprAst $lastAssign.Right -VariablePath $VariablePath) { return $false }

            return $true
        }

        # Helper: finds assignments to the variable in the same scope before loop start.
        function Get-PreLoopAssignments {
            param(
                [string]$VariablePath,
                [System.Management.Automation.Language.Ast]$LoopAncestor
            )
            # Find the enclosing scope: the nearest FunctionDefinitionAst or the
            # file-level ScriptBlockAst (whichever comes first walking upward).
            $scope = $LoopAncestor.Parent
            while ($null -ne $scope) {
                if ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    ($scope -is [System.Management.Automation.Language.ScriptBlockAst] -and $null -eq $scope.Parent)) {
                    break
                }
                $scope = $scope.Parent
            }
            if ($null -eq $scope) { return @() }

            $eqOp = [System.Management.Automation.Language.TokenKind]::Equals
            $loopStart = $LoopAncestor.Extent.StartOffset
            return @($scope.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $a.Operator -eq $eqOp -and
                $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $a.Left.VariablePath.UserPath -eq $VariablePath -and
                $a.Extent.EndOffset -lt $loopStart
            }, $true))
        }

        # Helper: returns $true when the variable is initialised with a numeric
        # literal (e.g. $total = 0) in the same scope before the loop.  This
        # identifies numeric accumulators so that $total += $obj.Count (O(1)
        # integer addition) is not flagged as array accumulation.
        function Test-NumericAccumulator {
            param(
                [string]$VariablePath,
                [System.Management.Automation.Language.Ast]$LoopAncestor
            )
            foreach ($init in (Get-PreLoopAssignments -VariablePath $VariablePath -LoopAncestor $LoopAncestor)) {
                if ($init.Right -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $innerExpr = $init.Right.Expression
                    if ($innerExpr -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                        $v = $innerExpr.Value
                        if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
                            return $true
                        }
                    }
                }
            }
            return $false
        }

        # Helper: returns $true when the variable is explicitly initialised with $null
        # before the loop in the same scope.
        function Test-NullAccumulatorInitializer {
            param(
                [string]$VariablePath,
                [System.Management.Automation.Language.Ast]$LoopAncestor
            )
            foreach ($init in (Get-PreLoopAssignments -VariablePath $VariablePath -LoopAncestor $LoopAncestor)) {
                if ($init.Right -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $innerExpr = $init.Right.Expression
                    if ($innerExpr -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $innerExpr.VariablePath.UserPath -eq 'null') {
                        return $true
                    }
                }
            }
            return $false
        }

        # Helper: syntactic numeric heuristic used only for null-initialised
        # accumulators so we can keep avoiding obvious numeric counters without
        # suppressing true array/string accumulation.
        function Test-ObviouslyNumericExpression {
            param(
                [System.Management.Automation.Language.Ast]$Expr,
                [string]$AccumulatorVariablePath
            )

            if ($null -eq $Expr) { return $false }

            if ($Expr -is [System.Management.Automation.Language.CommandExpressionAst]) {
                return (Test-ObviouslyNumericExpression -Expr $Expr.Expression -AccumulatorVariablePath $AccumulatorVariablePath)
            }
            if ($Expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
                return (Test-ObviouslyNumericExpression -Expr $Expr.Pipeline -AccumulatorVariablePath $AccumulatorVariablePath)
            }
            if ($Expr -is [System.Management.Automation.Language.PipelineAst]) {
                if ($Expr.PipelineElements.Count -ne 1) { return $false }
                $only = $Expr.PipelineElements[0]
                if ($only -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    return (Test-ObviouslyNumericExpression -Expr $only.Expression -AccumulatorVariablePath $AccumulatorVariablePath)
                }
                return $false
            }

            if ($Expr -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                $v = $Expr.Value
                return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal])
            }

            if ($Expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
                return ($Expr.VariablePath.UserPath -eq $AccumulatorVariablePath)
            }

            if ($Expr -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $Expr.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $memberName = $Expr.Member.Value
                if ($memberName -match '^(?i)(count|length|capacity|size|sum|total|numberof[a-z0-9_]*)$') {
                    return $true
                }
            }

            if ($Expr -is [System.Management.Automation.Language.BinaryExpressionAst]) {
                $numericOps = @(
                    [System.Management.Automation.Language.TokenKind]::Plus,
                    [System.Management.Automation.Language.TokenKind]::Minus,
                    [System.Management.Automation.Language.TokenKind]::Multiply,
                    [System.Management.Automation.Language.TokenKind]::Divide,
                    [System.Management.Automation.Language.TokenKind]::Rem
                )
                if ($numericOps -contains $Expr.Operator) {
                    return (
                        (Test-ObviouslyNumericExpression -Expr $Expr.Left -AccumulatorVariablePath $AccumulatorVariablePath) -and
                        (Test-ObviouslyNumericExpression -Expr $Expr.Right -AccumulatorVariablePath $AccumulatorVariablePath)
                    )
                }
            }

            return $false
        }

        # --- Pass 1: $var += $expr ---
        $plusEqualsOp = [System.Management.Automation.Language.TokenKind]::PlusEquals
        $assignments = $ScriptBlockAst.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $a.Operator -eq $plusEqualsOp
        }, $true)

        foreach ($assign in $assignments) {
            # 1a: Skip member-access ($obj.Prop += ...) and indexer ($hash['k'] += ...) LHS.
            if ($assign.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

            $loopAncestor = Get-LoopAncestor -Ast $assign
            if ($null -eq $loopAncestor) { continue }

            # 1b: Skip for-loop iterator ($i += $step is the loop step, not accumulation).
            if (Test-ForLoopIterator -AssignAst $assign -LoopAncestor $loopAncestor) { continue }

            # 1c: Skip numeric-constant RHS ($counter += 1 is O(1) integer addition).
            if (Test-NumericConstantRhs -RhsAst $assign.Right) { continue }

            # 1d: Skip numeric accumulators ($total = 0 before loop, then $total += $obj.Count).
            $varPath = $assign.Left.VariablePath.UserPath
            if (Test-NumericAccumulator -VariablePath $varPath -LoopAncestor $loopAncestor) { continue }
            if (Test-NullAccumulatorInitializer -VariablePath $varPath -LoopAncestor $loopAncestor) {
                if ($assign.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
                    (Test-ObviouslyNumericExpression -Expr $assign.Right.Expression -AccumulatorVariablePath $varPath)) {
                    continue
                }
            }
            if (Test-LoopLocalReinitializationBeforeAppend -VariablePath $varPath -CurrentAssign $assign -LoopAncestor $loopAncestor) { continue }

            $results.Add((New-ArrayLoopDiagnostic -AssignAst $assign -LhsText $assign.Left.Extent.Text))
        }

        # Helper: walks a Plus-operator chain to find a specific variable at any depth.
        # E.g. ($x + $a) + $b — finds $x by recursing into the left BinaryExpressionAst.
        function Find-VariableInPlusChain {
            param(
                [System.Management.Automation.Language.Ast]$Expr,
                [string]$VariablePath
            )
            if ($Expr -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $Expr.VariablePath.UserPath -eq $VariablePath) {
                return $true
            }
            if ($Expr -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                $Expr.Operator -eq [System.Management.Automation.Language.TokenKind]::Plus) {
                if (Find-VariableInPlusChain -Expr $Expr.Left -VariablePath $VariablePath) { return $true }
                if (Find-VariableInPlusChain -Expr $Expr.Right -VariablePath $VariablePath) { return $true }
            }
            return $false
        }

        # --- Pass 2: $var = $var + $expr (equivalent form) ---
        $equalsOp = [System.Management.Automation.Language.TokenKind]::Equals
        $equalsAssigns = $ScriptBlockAst.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $a.Operator -eq $equalsOp -and
            $a.Left -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)

        foreach ($assign in $equalsAssigns) {
            $loopAncestor = Get-LoopAncestor -Ast $assign
            if ($null -eq $loopAncestor) { continue }

            # Check if RHS is: $var + $something (BinaryExpressionAst with Plus)
            if ($assign.Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
            $expr = $assign.Right.Expression
            if ($expr -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { continue }
            if ($expr.Operator -ne [System.Management.Automation.Language.TokenKind]::Plus) { continue }

            $lhsPath = $assign.Left.VariablePath.UserPath

            # --- Try simple match: $var = $var + $expr ---
            $otherOperand = $null
            if ($expr.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $expr.Left.VariablePath.UserPath -eq $lhsPath) {
                $otherOperand = $expr.Right
            } elseif ($expr.Right -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $expr.Right.VariablePath.UserPath -eq $lhsPath) {
                $otherOperand = $expr.Left
            }

            if ($null -ne $otherOperand) {
                # Skip numeric constant additions (O(1) arithmetic, same as $var += 1).
                if ($otherOperand -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                    $val = $otherOperand.Value
                    if ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) {
                        continue
                    }
                }

                # Skip numeric accumulators ($total = 0 before loop, then $total = $total + $obj.Count).
                if (Test-NumericAccumulator -VariablePath $lhsPath -LoopAncestor $loopAncestor) { continue }
                if (Test-NullAccumulatorInitializer -VariablePath $lhsPath -LoopAncestor $loopAncestor) {
                    if (Test-ObviouslyNumericExpression -Expr $otherOperand -AccumulatorVariablePath $lhsPath) { continue }
                }
                if (Test-LoopLocalReinitializationBeforeAppend -VariablePath $lhsPath -CurrentAssign $assign -LoopAncestor $loopAncestor) { continue }

                $results.Add((New-ArrayLoopDiagnostic -AssignAst $assign -LhsText $assign.Left.Extent.Text))
            } elseif (Find-VariableInPlusChain -Expr $expr -VariablePath $lhsPath) {
                # Nested chain: $var = $var + $a + $b  (BinaryExpressionAst nesting)
                # No single "other operand" to check, rely on accumulator heuristic only.
                if (Test-NumericAccumulator -VariablePath $lhsPath -LoopAncestor $loopAncestor) { continue }
                if (Test-NullAccumulatorInitializer -VariablePath $lhsPath -LoopAncestor $loopAncestor) {
                    if (Test-ObviouslyNumericExpression -Expr $expr -AccumulatorVariablePath $lhsPath) { continue }
                }
                if (Test-LoopLocalReinitializationBeforeAppend -VariablePath $lhsPath -CurrentAssign $assign -LoopAncestor $loopAncestor) { continue }
                $results.Add((New-ArrayLoopDiagnostic -AssignAst $assign -LhsText $assign.Left.Extent.Text))
            }
        }

        return $results.ToArray()
    }
}
