[CmdletBinding()]
param(
    [string[]]$Targets = @(
        './PSCodePatrol.psm1',
        './Private',
        './Rules',
        './tools'
    ),
    [string]$SettingsPath = './PSScriptAnalyzerSettings.psd1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settingsFile = (Resolve-Path -LiteralPath $SettingsPath).Path
$allResults = New-Object System.Collections.Generic.List[object]

foreach ($target in $Targets) {
    if (-not (Test-Path -LiteralPath $target)) {
        throw "Analyzer target does not exist: $target"
    }

    $targetPath = (Resolve-Path -LiteralPath $target).Path
    $targetResults = Invoke-ScriptAnalyzer -Path $targetPath -Recurse -Settings $settingsFile

    foreach ($result in $targetResults) {
        [void]$allResults.Add($result)
    }
}

$severityRank = @{
    Error       = 0
    Warning     = 1
    Information = 2
}

$sortedResults = @(
    $allResults |
        Sort-Object @{
            Expression = {
                $severity = [string]$_.Severity
                if ($severityRank.ContainsKey($severity)) {
                    return $severityRank[$severity]
                }
                return 99
            }
        }, ScriptPath, Line, Column, RuleName
)

if ($sortedResults.Count -eq 0) {
    Write-Output 'PSScriptAnalyzer: no findings.'
    return
}

Write-Output "PSScriptAnalyzer findings: $($sortedResults.Count)"
foreach ($group in ($sortedResults | Group-Object Severity | Sort-Object Name)) {
    Write-Output ('Severity={0} Count={1}' -f $group.Name, $group.Count)
}

$table = $sortedResults |
    Select-Object Severity, RuleName, ScriptPath, Line, Column, Message |
    Format-Table -Wrap -AutoSize |
    Out-String -Width 240
Write-Output $table

throw "PSScriptAnalyzer reported $($sortedResults.Count) finding(s)."
