function ConvertTo-CorrectionCollection {
    param([System.Collections.Generic.IEnumerable[object]]$Items)

    $genericType =
    'System.Collections.ObjectModel.Collection[' +
    'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent]'
    $col = New-Object -TypeName $genericType
    foreach ($i in $Items) { $null = $col.Add($i) }
    return , $col
}
