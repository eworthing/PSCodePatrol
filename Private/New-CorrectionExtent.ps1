function New-CorrectionExtent {
    param(
        [int]$StartLine,
        [int]$EndLine,
        [int]$StartColumn,
        [int]$EndColumn,
        [string]$ReplacementText,
        [string]$FilePath,
        [string]$Description
    )

    $typeName = 'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent'
    return New-Object -TypeName $typeName -ArgumentList @(
        $StartLine, $EndLine, $StartColumn, $EndColumn,
        $ReplacementText, $FilePath, $Description
    )
}
