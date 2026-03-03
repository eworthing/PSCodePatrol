function New-Diagnostic {
    param(
        [string]$Message,
        [System.Management.Automation.Language.IScriptExtent]$Extent,
        [ValidateSet('Information','Warning','Error')]
        [string]$Severity,
        [string]$RuleName,
        [System.Collections.IEnumerable]$SuggestedCorrections
    )

    $h = @{
        Message  = $Message
        Extent   = $Extent
        RuleName = $RuleName
        Severity = $Severity
    }

    if ($SuggestedCorrections) {
        $h.SuggestedCorrections = New-CorrectionCollection -Items $SuggestedCorrections
    }

    return [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]$h
}
