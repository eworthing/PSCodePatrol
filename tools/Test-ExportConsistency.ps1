[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$RulesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repoRoot 'PSCodePatrol.psd1'
}
if (-not $RulesPath) {
    $RulesPath = Join-Path $repoRoot 'Rules'
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest path not found: $ManifestPath"
}
if (-not (Test-Path -LiteralPath $RulesPath)) {
    throw "Rules path not found: $RulesPath"
}

$manifest = Import-PowerShellDataFile -Path $ManifestPath
$manifestExports = @($manifest.FunctionsToExport | ForEach-Object { [string]$_ }) | Sort-Object -Unique
$ruleExports = @(Get-ChildItem -LiteralPath $RulesPath -Filter '*.ps1' -File | ForEach-Object BaseName) | Sort-Object -Unique

$missingInManifest = @($ruleExports | Where-Object { $_ -notin $manifestExports })
$missingRuleFile = @($manifestExports | Where-Object { $_ -notin $ruleExports })

if ($missingInManifest.Count -gt 0 -or $missingRuleFile.Count -gt 0) {
    if ($missingInManifest.Count -gt 0) {
        Write-Host 'Rules missing in FunctionsToExport:'
        $missingInManifest | ForEach-Object { Write-Host "  - $_" }
    }

    if ($missingRuleFile.Count -gt 0) {
        Write-Host 'FunctionsToExport entries missing corresponding rule files:'
        $missingRuleFile | ForEach-Object { Write-Host "  - $_" }
    }

    throw 'FunctionsToExport is out of sync with Rules/*.ps1.'
}

Write-Host 'FunctionsToExport matches Rules/*.ps1.'
