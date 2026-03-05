[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ModuleRoot,

    [Parameter(Mandatory)]
    [string]$PfxPath,

    [Parameter(Mandatory)]
    [securestring]$PfxPassword,

    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Signing is supported only on Windows (Set-AuthenticodeSignature limitation).'
}

if (-not (Test-Path -LiteralPath $ModuleRoot)) {
    throw "Module root not found: $ModuleRoot"
}
if (-not (Test-Path -LiteralPath $PfxPath)) {
    throw "PFX file not found: $PfxPath"
}

$cert = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation 'Cert:\CurrentUser\My' -Password $PfxPassword
if (-not $cert) {
    throw 'Failed to import code-signing certificate from PFX.'
}
if (-not $cert.HasPrivateKey) {
    throw 'Imported certificate does not include a private key.'
}

$filesToSign = @(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1', '.psd1')
})

if ($filesToSign.Count -eq 0) {
    throw "No signable files found under: $ModuleRoot"
}

foreach ($file in $filesToSign) {
    $signature = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $cert -HashAlgorithm 'SHA256' -TimestampServer $TimestampServer -IncludeChain 'NotRoot'
    if ($signature.Status -ne 'Valid') {
        throw "Signing failed for '$($file.FullName)' with status '$($signature.Status)'."
    }
}

foreach ($file in $filesToSign) {
    $signature = Get-AuthenticodeSignature -FilePath $file.FullName
    if ($signature.Status -ne 'Valid') {
        throw "Signature verification failed for '$($file.FullName)' with status '$($signature.Status)'."
    }
}

Write-Host "Signed $($filesToSign.Count) files under $ModuleRoot"
