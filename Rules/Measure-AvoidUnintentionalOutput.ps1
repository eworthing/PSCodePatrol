function Measure-AvoidUnintentionalOutput {
    <#
    .SYNOPSIS
        Flags .NET method calls whose return values are not captured.

    .DESCRIPTION
        In PowerShell, every uncaptured expression emits to the output stream. When
        .NET methods that return non-void values are called as standalone statements,
        their return values silently pollute the function's output. This is the most
        common PowerShell mistake made by LLM coding agents and developers coming
        from C# or Python, where discarded return values are the norm.

        Examples of problematic code:
            $list.Add("item")       # ArrayList.Add returns int (the index)
            $sb.Append("text")      # StringBuilder.Append returns the StringBuilder
            $dict.Remove("key")     # Dictionary.Remove returns bool

        Fix: suppress unwanted output with [void] or assign to $null:
            [void]$list.Add("item")
            $null = $sb.Append("text")
            $list.Add("item") | Out-Null

    .PARAMETER ScriptBlockAst
        ScriptBlockAst provided by PSScriptAnalyzer.

    .EXAMPLE
        Invoke-ScriptAnalyzer -ScriptDefinition '$list.Add("item")' `
            -CustomRulePath ./PSCodePatrol/PSCodePatrol.psm1 `
            -IncludeRule 'Measure-AvoidUnintentionalOutput'

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

        $ruleName = 'Measure-AvoidUnintentionalOutput'
        $results = [System.Collections.Generic.List[object]]::new()

        # ── Helper: determine whether an InvokeMemberExpressionAst is an uncaptured
        #    standalone statement (return value is discarded into the output stream). ──
        function Test-IsUncapturedMethodCall {
            param(
                [System.Management.Automation.Language.InvokeMemberExpressionAst]$Node
            )

            $current = $Node

            while ($null -ne $current) {
                $parent = $current.Parent
                if ($null -eq $parent) { return $false }

                # [void] cast — output is explicitly suppressed.
                if ($parent -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                    $typeName = $parent.Type.TypeName.Name
                    if ($typeName -eq 'void') { return $false }
                }

                # Assignment RHS — value is captured in a variable ($x = ... or $null = ...).
                if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                    return $false
                }

                # Argument to a command — value is consumed by the cmdlet.
                # e.g. Write-Host $sb.ToString()  →  the InvokeMemberExpressionAst is a
                # child of CommandAst but is NOT the first element (the command name).
                if ($parent -is [System.Management.Automation.Language.CommandAst]) {
                    return $false
                }

                # CommandExpressionAst is the wrapper; keep walking to reach PipelineAst.
                if ($parent -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $current = $parent
                    continue
                }

                # PipelineAst — the statement boundary.
                if ($parent -is [System.Management.Automation.Language.PipelineAst]) {
                    # If the pipeline has more than one element, the value is piped
                    # to another command (e.g. | Out-Null, | ForEach-Object).
                    if ($parent.PipelineElements.Count -gt 1) { return $false }

                    # If the pipeline's parent is a return statement, the value is consumed.
                    if ($parent.Parent -is [System.Management.Automation.Language.ReturnStatementAst]) {
                        return $false
                    }

                    # Single-element pipeline as a standalone statement → uncaptured.
                    return $true
                }

                $current = $parent
            }

            return $false
        }

        # ── Curated blocklist of method names known to return non-void values ──
        # These are methods on common .NET types (collections, StringBuilder, String,
        # IO streams) that LLMs and newcomers frequently call without capturing output.
        $nonVoidMethods = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $methodNames = @(
            # Collections (ArrayList.Add returns int; HashSet/List Remove returns bool)
            'Add', 'Remove', 'Pop', 'Dequeue', 'Peek',
            'Contains', 'ContainsKey', 'ContainsValue',
            'IndexOf', 'LastIndexOf',
            # StringBuilder (returns the StringBuilder itself)
            'Append', 'AppendLine', 'AppendFormat',
            # String (returns new string)
            'Replace', 'ToString', 'Substring',
            'Trim', 'TrimStart', 'TrimEnd',
            'ToUpper', 'ToLower', 'Split',
            # IO / Stream
            'Read', 'ReadByte', 'ReadLine', 'ReadToEnd',
            'ReadAllText', 'ReadAllLines',
            # General
            'Clone', 'GetType', 'GetHashCode'
        )
        foreach ($m in $methodNames) { $null = $nonVoidMethods.Add($m) }

        # ── Find all method invocations (instance and static) ──
        $invocations = $ScriptBlockAst.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true)

        foreach ($invoke in $invocations) {
            # Extract method name from the Member property.
            if ($invoke.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                continue
            }
            $methodName = $invoke.Member.Value
            if (-not $nonVoidMethods.Contains($methodName)) { continue }

            # ── Walk parent chain to determine if the return value is consumed ──
            if (-not (Test-IsUncapturedMethodCall -Node $invoke)) { continue }

            # Find the enclosing CommandExpressionAst for the auto-fix extent.
            $cmdExpr = $invoke
            while ($null -ne $cmdExpr -and $cmdExpr -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                $cmdExpr = $cmdExpr.Parent
            }
            if ($null -eq $cmdExpr) { continue }

            $extent = $cmdExpr.Extent
            $fixParams = @{
                StartLine       = $extent.StartLineNumber
                EndLine         = $extent.EndLineNumber
                StartColumn     = $extent.StartColumnNumber
                EndColumn       = $extent.EndColumnNumber
                ReplacementText = "[void]$($extent.Text)"
                FilePath        = $extent.File
                Description     = "Prepend [void] to suppress unintentional output from .$methodName()."
            }
            $fix = ConvertTo-CorrectionExtent @fixParams

            $msg = "Method '.$methodName()' returns a value that is not captured, which pollutes the output stream. " +
            'Suppress with [void], assign to $null, or pipe to Out-Null.'

            $diagParams = @{
                Message              = $msg
                Extent               = $extent
                Severity             = 'Warning'
                RuleName             = $ruleName
                SuggestedCorrections = @($fix)
            }
            $results.Add((ConvertTo-DiagnosticRecord @diagParams))
        }

        return $results.ToArray()
    }
}
