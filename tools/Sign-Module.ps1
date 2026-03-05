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

$cert = $null
$pfxPasswordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
try {
    $pfxPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pfxPasswordBstr)
    $x509Flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $x509Flags = $x509Flags -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $PfxPath,
        $pfxPasswordPlain,
        $x509Flags
    )
}
catch {
    throw "Failed to load code-signing certificate from PFX '$PfxPath': $_"
}
finally {
    if ($pfxPasswordBstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pfxPasswordBstr)
    }
}

if ($null -eq $cert) {
    throw 'Failed to load code-signing certificate from PFX.'
}
if (-not $cert.HasPrivateKey) {
    throw 'Loaded certificate does not include a private key.'
}

$filesToSign = @(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File | Where-Object {
        $_.Extension -in @('.ps1', '.psm1', '.psd1')
    })

if ($filesToSign.Count -eq 0) {
    throw "No signable files found under: $ModuleRoot"
}

foreach ($file in $filesToSign) {
    $signatureParams = @{
        FilePath        = $file.FullName
        Certificate     = $cert
        HashAlgorithm   = 'SHA256'
        TimestampServer = $TimestampServer
        IncludeChain    = 'NotRoot'
    }
    $signature = Set-AuthenticodeSignature @signatureParams
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

Write-Output "Signed $($filesToSign.Count) files under $ModuleRoot"
