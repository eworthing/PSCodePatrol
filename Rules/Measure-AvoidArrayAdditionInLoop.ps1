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

        # Helper: returns $true when the variable is initialised with a numeric
        # literal (e.g. $total = 0) in the same scope before the loop.  This
        # identifies numeric accumulators so that $total += $obj.Count (O(1)
        # integer addition) is not flagged as array accumulation.
        function Test-NumericAccumulator {
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
            if ($null -eq $scope) { return $false }

            $eqOp = [System.Management.Automation.Language.TokenKind]::Equals
            $loopStart = $LoopAncestor.Extent.StartOffset
            $scopeAssigns = $scope.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $a.Operator -eq $eqOp -and
                $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $a.Left.VariablePath.UserPath -eq $VariablePath -and
                $a.Extent.EndOffset -lt $loopStart
            }, $true)

            foreach ($init in $scopeAssigns) {
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

            $results.Add((New-ArrayLoopDiagnostic -AssignAst $assign -LhsText $assign.Left.Extent.Text))
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
            $otherOperand = $null
            if ($expr.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $expr.Left.VariablePath.UserPath -eq $lhsPath) {
                $otherOperand = $expr.Right
            } elseif ($expr.Right -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $expr.Right.VariablePath.UserPath -eq $lhsPath) {
                $otherOperand = $expr.Left
            }
            if ($null -eq $otherOperand) { continue }

            # Skip numeric constant additions (O(1) arithmetic, same as $var += 1).
            if ($otherOperand -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                $val = $otherOperand.Value
                if ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) {
                    continue
                }
            }

            # Skip numeric accumulators ($total = 0 before loop, then $total = $total + $obj.Count).
            if (Test-NumericAccumulator -VariablePath $lhsPath -LoopAncestor $loopAncestor) { continue }

            $results.Add((New-ArrayLoopDiagnostic -AssignAst $assign -LhsText $assign.Left.Extent.Text))
        }

        return $results.ToArray()
    }
}
