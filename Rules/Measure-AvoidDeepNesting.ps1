function Measure-AvoidDeepNesting {
    <#
    .SYNOPSIS
        Enforces a maximum control-flow nesting depth for functions.

    .DESCRIPTION
        Reports a warning when a function exceeds the maximum allowed control-flow nesting depth.

        Max depth is computed by counting nested bodies of:
          - if / elseif / else
          - foreach / for / while / do-while / do-until
          - switch
          - try / catch / finally
          - trap

        This rule is designed for PowerShell 5.1 compatibility and intentionally does not
        inspect nested scriptblocks used as command arguments (for example ForEach-Object { }).

        Suppressions are supported via SuppressMessageAttribute on the function definition.

	        Example suppression (use sparingly):
	          [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
	              'Measure-AvoidDeepNesting',
	              '',
	              Scope = 'Function',
	              Target = 'Invoke-ExampleFunction',
	              Justification = 'Refactor would reduce correctness or readability for this case.'
	          )]
          function Invoke-ExampleFunction { ... }
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst
    )

	    $maxAllowedDepth = 4
	    $ruleName = 'Measure-AvoidDeepNesting'
	    $diagnostics = New-Object System.Collections.Generic.List[object]

    function Get-MaxControlFlowDepth {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [System.Management.Automation.Language.ScriptBlockAst]$BodyAst
        )

        $script:MaxDepth = 0

        function Visit-StatementBlock {
            param(
                [System.Management.Automation.Language.StatementBlockAst]$Block,
                [int]$Depth
            )

            if ($null -eq $Block) { return }

            if ($Depth -gt $script:MaxDepth) {
                $script:MaxDepth = $Depth
            }

            foreach ($Statement in $Block.Statements) {
                Visit-Statement -Ast $Statement -Depth $Depth
            }
        }

        function Visit-Statement {
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [int]$Depth
            )

            if ($null -eq $Ast) { return }

            if ($Ast -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($Clause in $Ast.Clauses) {
                    Visit-StatementBlock -Block $Clause.Item2 -Depth ($Depth + 1)
                }

                if ($Ast.ElseClause) {
                    Visit-StatementBlock -Block $Ast.ElseClause -Depth ($Depth + 1)
                }

                return
            }

            if ($Ast -is [System.Management.Automation.Language.SwitchStatementAst]) {
                foreach ($Clause in $Ast.Clauses) {
                    if ($null -ne $Clause -and $null -ne $Clause.Item2) {
                        Visit-StatementBlock -Block $Clause.Item2 -Depth ($Depth + 1)
                    }
                }

                if ($Ast.Default) {
                    Visit-StatementBlock -Block $Ast.Default -Depth ($Depth + 1)
                }

                return
            }

            if ($Ast -is [System.Management.Automation.Language.TryStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)

                foreach ($CatchClause in $Ast.CatchClauses) {
                    Visit-StatementBlock -Block $CatchClause.Body -Depth ($Depth + 1)
                }

                if ($Ast.Finally) {
                    Visit-StatementBlock -Block $Ast.Finally -Depth ($Depth + 1)
                }

                return
            }

            if ($Ast -is [System.Management.Automation.Language.ForEachStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)
                return
            }

            if ($Ast -is [System.Management.Automation.Language.ForStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)
                return
            }

            if ($Ast -is [System.Management.Automation.Language.WhileStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)
                return
            }

            if ($Ast -is [System.Management.Automation.Language.DoWhileStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)
                return
            }

            if ($Ast -is [System.Management.Automation.Language.DoUntilStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)
                return
            }

            if ($Ast -is [System.Management.Automation.Language.TrapStatementAst]) {
                Visit-StatementBlock -Block $Ast.Body -Depth ($Depth + 1)
                return
            }
        }

        foreach ($NamedBlock in @(
                $BodyAst.BeginBlock,
                $BodyAst.ProcessBlock,
                $BodyAst.EndBlock,
                $BodyAst.DynamicParamBlock
            )) {
            if ($NamedBlock -and $NamedBlock.Statements) {
                foreach ($Statement in $NamedBlock.Statements) {
                    Visit-Statement -Ast $Statement -Depth 0
                }
            }
        }

        return $script:MaxDepth
    }

    $functions = $ScriptBlockAst.FindAll({
            param($A)
            $A -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)

    foreach ($fn in $functions) {
        $depth = Get-MaxControlFlowDepth -BodyAst $fn.Body

        if ($depth -le $maxAllowedDepth) { continue }

        $message = "Function '{0}' is nested {1} levels deep (maximum: {2}). Refactor (guard clauses/extract helpers) or suppress with SuppressMessageAttribute." -f $fn.Name, $depth, $maxAllowedDepth

        $diagnostics.Add((New-Diagnostic -Message $message -Extent $fn.Extent -Severity 'Warning' -RuleName $ruleName))
	    }

    return $diagnostics
}
