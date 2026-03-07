# PSCodePatrol.psm1
# Custom PSScriptAnalyzer rules for PowerShell code quality, PS 5.1 compatibility,
# and anti-obfuscation.
Set-StrictMode -Version Latest

$Private = @(Get-ChildItem -Path "$PSScriptRoot/Private/*.ps1" -ErrorAction SilentlyContinue)
$Rules   = @(Get-ChildItem -Path "$PSScriptRoot/Rules/*.ps1"   -ErrorAction SilentlyContinue)

foreach ($file in @($Private + $Rules)) {
    try { . $file.FullName }
    catch { throw "Failed to import $($file.FullName): $($_.Exception.Message)" }
}

Export-ModuleMember -Function $Rules.BaseName
