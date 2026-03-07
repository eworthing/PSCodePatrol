# Release Runbook

## Scope
This runbook defines the release process for publishing `PSCodePatrol` to PowerShell Gallery.

## Tag and Version Rules
1. Update `PSCodePatrol.psd1` `ModuleVersion` using SemVer (`X.Y.Z`).
2. Add release notes to `CHANGELOG.md`.
3. Push a tag that exactly matches the manifest version in the format `vX.Y.Z`.

## Required Secrets
Create a protected GitHub Environment named `psgallery` and store:
- `PSGALLERY_API_KEY`
- `CODESIGN_PFX_BASE64`
- `CODESIGN_PFX_PASSWORD`

Use scoped PowerShell Gallery API keys with package restrictions (`PSCodePatrol*`) and expiration.

## Pre-Release Validation
Before tagging, ensure CI is green and run locally when possible:

```powershell
Test-ModuleManifest -Path ./PSCodePatrol.psd1
./tools/Test-ExportConsistency.ps1
$targets = './PSCodePatrol.psm1', './Private', './Rules', './tools'
$results = foreach ($target in $targets) { Invoke-ScriptAnalyzer -Path $target -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 }
$results | Where-Object Severity -eq 'Error'
Invoke-Pester -Path ./Tests -CI -Output Detailed
```

## Publish Flow
1. Push version tag (`vX.Y.Z`).
2. Publish workflow validates manifest, analyzer gate, and Pester tests.
3. Publish workflow verifies the tag commit is on `main`.
4. Workflow stages module content into `out/PSCodePatrol`.
5. Workflow signs all `.ps1`, `.psm1`, and `.psd1` files.
6. Workflow publishes with `Publish-Module` to PSGallery.
7. Workflow performs post-publish discoverability check with `Find-Module`.

## Rollback and Incident Response
If a bad package version is released:
1. Publish a fixed higher patch version immediately.
2. Unlist affected package version from PSGallery as needed.
3. If secrets were exposed, rotate all impacted secrets immediately.
4. Regenerate PSGallery API keys and replace GitHub secrets.

## Notes
- Signing is required for release publishes.
- Do not publish from local ad-hoc scripts outside this process.
