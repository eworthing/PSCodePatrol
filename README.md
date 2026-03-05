# PSCodePatrol

Custom [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) rules for PowerShell code quality, PS 5.1 compatibility, and anti-obfuscation.

## Installation

### Requirements

- PowerShell 5.1+ (`powershell.exe` or `pwsh`)
- [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)

### Install from PSGallery (recommended)

```powershell
Install-Module PSCodePatrol -Repository PSGallery -Scope CurrentUser
```

### Quick install (git)

```powershell
git clone https://github.com/eworthing/PSCodePatrol.git
```

> You don’t need to `Import-Module` for PSScriptAnalyzer custom rules.
> Just point `-CustomRulePath` at the cloned folder.

<details>
<summary>Alternative clone options</summary>

```powershell
# If you prefer GitHub CLI:
gh repo clone eworthing/PSCodePatrol
```

```powershell
# SSH:
git clone git@github.com:eworthing/PSCodePatrol.git
```

</details>

## Usage

Run all rules against a script:

```powershell
$analyzerParams = @{
    Path           = './MyScript.ps1'
    CustomRulePath = './PSCodePatrol'
}
Invoke-ScriptAnalyzer @analyzerParams
```

Run a specific rule:

```powershell
$analyzerParams = @{
    Path           = './MyScript.ps1'
    CustomRulePath = './PSCodePatrol'
    IncludeRule    = 'Measure-AvoidArrayAdditionInLoop'
}
Invoke-ScriptAnalyzer @analyzerParams
```

Use in a `PSScriptAnalyzerSettings.psd1` config file:

```powershell
@{
    CustomRulePath        = @('./PSCodePatrol')
    IncludeDefaultRules   = $true
}
```

Then invoke with:

```powershell
Invoke-ScriptAnalyzer -Path './MyScript.ps1' -Settings './PSScriptAnalyzerSettings.psd1'
```

## Rules

| Rule | Severity | AutoFix | Description |
|------|----------|---------|-------------|
| [AvoidArrayAdditionInLoop](#avoidarrayadditioninloop) | Warning | No | Detects `+=` array accumulation inside loops (O(n^2) performance) |
| [AvoidBacktickLineContinuation](#avoidbackticklinecontinuation) | Warning | Partial | Flags backtick line continuations |
| [AvoidBacktickBrokenContinuationAttempt](#avoidbacktickbrokencontinuationattempt) | Warning | No | Detects backtick + trailing whitespace (broken continuation) |
| [AvoidBacktickObfuscationNoOpInIdentifier](#avoidbacktickobfuscationnoop-inidentifier) | Warning | Yes | Catches no-op backticks used for obfuscation |
| [AvoidDeepNesting](#avoiddeepnesting) | Warning | No | Enforces max control-flow nesting depth (default: 4) |
| [AvoidEnvPlatformSpecificVariable](#avoidenvplatformspecificvariable) | Error | Yes | Flags Windows-only `$env:` variables that fail on macOS/Linux |
| [RequireConvertToJsonDepth](#requireconverttojsondepth) | Warning | Yes | Requires explicit `-Depth` on `ConvertTo-Json` |
| [UnsafeCountProperty](#unsafecountproperty) | Warning | Yes | Detects `.Count` usage that fails on PowerShell 5.1 |

### AvoidArrayAdditionInLoop

Flags `$arr += $item` and `$arr = $arr + $item` inside `foreach`, `for`, `while`, `do-while`, `do-until`, and `ForEach-Object`. Arrays are immutable in PowerShell, so `+=` copies the entire array on every iteration, resulting in O(n^2) performance.

```powershell
# Bad - O(n^2)
$results = @()
foreach ($item in $collection) {
    $results += $item
}

# Good - let PowerShell collect pipeline output
$results = @(foreach ($item in $collection) {
    $item
})

# Good - use a List for add/remove
$results = [System.Collections.Generic.List[object]]::new()
foreach ($item in $collection) {
    $results.Add($item)
}
```

Excludes safe patterns: member/indexer LHS (`$obj.Prop += ...`), numeric-constant RHS (`$count += 1`), and numeric accumulators.

### AvoidBacktickLineContinuation

Flags backtick (`` ` ``) line continuations. Classifies each as **Redundant** (backtick is unnecessary because the line already continues naturally) or **Structural** (removing the backtick would break parsing). Redundant backticks have auto-fix corrections; structural cases require manual refactoring.

```powershell
# Bad - structural backtick
$result = Get-Process `
    -Name "pwsh"

# Good - use splatting
$params = @{ Name = "pwsh" }
$result = Get-Process @params

# Good - use natural continuation after pipe
$result = Get-Process |
    Where-Object { $_.CPU -gt 10 }
```

### AvoidBacktickBrokenContinuationAttempt

Detects a backtick followed by whitespace then a newline. This pattern looks like a line continuation but the trailing whitespace breaks it, so the backtick escapes the space character instead of the newline. This is a silent bug.

### AvoidBacktickObfuscationNoOpInIdentifier

Flags no-op backticks inside identifiers such as `` Ge`t-Chi`ldItem ``. These backticks do nothing (the backtick escape before a regular character is a no-op) and are commonly used for obfuscation in malicious scripts. Auto-fix removes them.

### AvoidDeepNesting

Enforces a maximum control-flow nesting depth (default: 4 levels). Counts nesting from `if`, `elseif`, `else`, `foreach`, `for`, `while`, `do-while`, `do-until`, `switch`, `try`, `catch`, `finally`, and `trap`. Deeply nested code is harder to read and test; consider extracting helper functions.

### AvoidEnvPlatformSpecificVariable

Flags `$env:` variables that only exist on Windows and provides cross-platform replacements.

| Variable | Replacement |
|----------|-------------|
| `$env:USERNAME` | `[Environment]::UserName` |
| `$env:COMPUTERNAME` | `[Environment]::MachineName` |
| `$env:USERPROFILE` | `$HOME` |
| `$env:APPDATA` | `[Environment]::GetFolderPath('ApplicationData')` |
| `$env:LOCALAPPDATA` | `[Environment]::GetFolderPath('LocalApplicationData')` |

Auto-fix handles expandable strings and sub-expressions with proper `$()` wrapping. Variables without safe 1:1 replacements (`$env:TEMP`, `$env:TMP`, `$env:HOMEDRIVE`, `$env:HOMEPATH`) emit a warning without auto-fix.

### RequireConvertToJsonDepth

Flags `ConvertTo-Json` calls that omit the `-Depth` parameter. The default depth of 2 silently truncates nested objects, replacing them with their `.ToString()` representation (e.g., `@{Key=Value}`). Auto-fix suggests `-Depth 10`.

### UnsafeCountProperty

Detects `.Count` property access on variables that may be `$null` or a scalar in PowerShell 5.1. PS 5.1 lacks the universal `.Count` property that PS 7+ provides, so `$null.Count` returns `$null` (not 0) and `$scalar.Count` throws an error.

```powershell
# Bad - unsafe on PS 5.1
$users = Get-ADUser -Filter *
if ($users.Count -gt 0) { ... }

# Good - wrap in @() for reliable count
$users = @(Get-ADUser -Filter *)
if ($users.Count -gt 0) { ... }
```

## Running Tests

```powershell
Invoke-Pester ./Tests -Output Detailed
```

## Maintainer Validation

```powershell
Test-ModuleManifest -Path ./PSCodePatrol.psd1
./tools/Test-ExportConsistency.ps1
$targets = './PSCodePatrol.psm1', './Private', './Rules'
$results = foreach ($target in $targets) { Invoke-ScriptAnalyzer -Path $target -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 }
$results | Where-Object Severity -eq 'Error'
Invoke-Pester -Path ./Tests -CI -Output Detailed
./tools/Stage-Module.ps1 -OutDir ./out/PSCodePatrol
Test-ModuleManifest -Path ./out/PSCodePatrol/PSCodePatrol.psd1
```

## Release Process

- See [docs/RELEASE.md](docs/RELEASE.md) for the tag-driven signed publish flow.
- See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

[MIT](LICENSE)
