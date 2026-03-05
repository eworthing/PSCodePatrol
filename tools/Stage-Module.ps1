[CmdletBinding()]
param(
    [string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutDir) {
    $outRoot = Join-Path $repoRoot 'out'
    $OutDir = Join-Path $outRoot 'PSCodePatrol'
}

if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null

$rootFiles = @(
    'PSCodePatrol.psd1'
    'PSCodePatrol.psm1'
    'README.md'
    'LICENSE'
    'CHANGELOG.md'
)

foreach ($file in $rootFiles) {
    $sourcePath = Join-Path $repoRoot $file
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required file missing for staging: $sourcePath"
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $OutDir $file) -Force
}

$directories = @('Private', 'Rules')
foreach ($directory in $directories) {
    $sourcePath = Join-Path $repoRoot $directory
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required directory missing for staging: $sourcePath"
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $OutDir $directory) -Recurse -Force
}

Write-Output "Staged module to: $OutDir"
