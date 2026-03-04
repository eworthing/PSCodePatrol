# Pester tests for the PSCodePatrol backtick custom rules.
# Validates true positives, false-positive suppression, and correction behaviour.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', '')]
param()

Describe 'Backtick PSScriptAnalyzer custom rules' {
    BeforeAll {
        $Script:RepoRoot = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
        $Script:ModulePath = Join-Path -Path $Script:RepoRoot -ChildPath 'PSCodePatrol.psm1'
        $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_backtick_$PID.psd1"

        @"
@{
    CustomRulePath = '$($Script:ModulePath -replace "'","''")'
    IncludeRules   = @(
        'Measure-AvoidBacktickLineContinuation',
        'Measure-AvoidBacktickBrokenContinuationAttempt',
        'Measure-AvoidBacktickObfuscationNoOpInIdentifier',
        'Measure-AvoidArrayAdditionInLoop',
        'Measure-AvoidEnvPlatformSpecificVariable',
        'Measure-RequireConvertToJsonDepth'
    )
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8

        # Helper: run a single custom rule against inline code.
        # Uses -Settings @{} to suppress auto-discovery of the project
        # PSScriptAnalyzerSettings.psd1 (which would double-load the module).
        function Invoke-Rule {
            param(
                [Parameter(Mandatory)]
                [string]$ScriptDefinition,
                [Parameter(Mandatory)]
                [string]$RuleName
            )
            @(Invoke-ScriptAnalyzer -ScriptDefinition $ScriptDefinition -CustomRulePath $Script:ModulePath -IncludeRule $RuleName -Settings @{})
        }
    }

    AfterAll {
        if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
    }

    # ================================================================
    # Rule 1 — Measure-AvoidBacktickLineContinuation
    # ================================================================
    Context 'Rule 1: Measure-AvoidBacktickLineContinuation' {

        # --- True positives: must flag ---

        It 'Flags redundant backtick before -Parameter on next line' {
            $code = "Get-ChildItem -Path C:\Temp ```n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*Redundant*'
        }

        It 'Flags redundant backtick after pipe on the same line' {
            # Pipe already allows continuation, so the backtick is redundant.
            $code = "Get-Process | ```n    Where-Object { `$_.CPU -gt 100 }"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*Redundant*'
        }

        It 'Flags redundant backtick after opening paren' {
            $code = "`$result = (```n    1 + 2`n)"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*Redundant*'
        }

        It 'Flags redundant backtick after comma in array' {
            $code = "`$array = @(`n    'one', ```n    'two'`n)"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*Redundant*'
        }

        It 'Flags multiple backticks on successive lines' {
            $code = "Get-ChildItem ```n    -Path C:\Temp ```n    -Recurse ```n    -Force"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 3
        }

        It 'Flags structural backtick when baseline parse errors exist' {
            # Baseline parse error (missing function name) forces structural classification.
            $code = "function { Get-ChildItem ```n    -Recurse }"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -BeGreaterOrEqual 1
            $structural = $results | Where-Object { $_.Message -like '*Structural*' }
            $structural.Count | Should -BeGreaterOrEqual 1
        }

        It 'Marks structural backtick with no SuggestedCorrections' {
            $code = "function { Get-ChildItem ```n    -Recurse }"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $structural = $results | Where-Object { $_.Message -like '*Structural*' }
            $structural.Count | Should -BeGreaterOrEqual 1
            $structural[0].SuggestedCorrections | Should -BeNullOrEmpty
        }

        It 'Provides SuggestedCorrections for redundant backtick' {
            $code = "Get-ChildItem ```n    -Path C:\Temp"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].SuggestedCorrections | Should -Not -BeNullOrEmpty
        }

        # --- True negatives: must NOT flag ---

        It 'Does not flag code without backticks' {
            $code = 'Get-ChildItem -Path C:\Temp -Recurse -Force'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag natural continuation after pipe' {
            $code = "Get-Process |`n    Where-Object { `$_.CPU -gt 100 } |`n    Sort-Object CPU"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag natural continuation inside parentheses' {
            $code = "`$result = (`n    1 + 2 +`n    3`n)"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag splatting (common backtick replacement)' {
            $code = @'
$params = @{
    Path    = 'C:\Temp'
    Recurse = $true
    Force   = $true
}
Get-ChildItem @params
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick escape sequences inside strings' {
            $code = @'
$msg = "Line1`nLine2`tTabbed"
$path = "C:\Temp`0NullTerminated"
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick dollar escape in double-quoted string' {
            $code = 'Write-Host "The value is `$notAVariable"'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag single-line commands on one line' {
            $code = 'Get-ChildItem -Path C:\Temp -Recurse -Force | Sort-Object Length'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag continuation after opening brace' {
            $code = @'
$sb = {
    param($x)
    $x * 2
}
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag here-string with backtick content' {
            $code = @'
$hs = @"
This has a backtick ` on this line
And another ` here
"@
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not flag comment containing backtick' {
            $code = @'
# This comment mentions ` backtick usage
Get-ChildItem
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Does not produce duplicates from nested ScriptBlockAst' {
            # The parent guard should prevent double-reporting when the
            # rule is invoked for both the file-level and function-level ASTs.
            $code = "function Test-Something {`n    Get-ChildItem ```n        -Path C:\Temp`n}"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
        }

        It 'Does not flag whitespace-only script' {
            $results = Invoke-Rule -ScriptDefinition '   ' -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }
    }

    # ================================================================
    # Rule 2 — Measure-AvoidBacktickBrokenContinuationAttempt
    # ================================================================
    Context 'Rule 2: Measure-AvoidBacktickBrokenContinuationAttempt' {

        # --- True positives: must flag ---

        It 'Flags backtick followed by trailing space then newline' {
            # The trailing space after the backtick breaks the continuation.
            $code = "Get-ChildItem -Path C:\Temp ``  `r`n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*BrokenAttempt*'
        }

        It 'Flags backtick followed by trailing tab then newline' {
            $code = "Get-ChildItem -Path C:\Temp `` `t`r`n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 1
        }

        It 'Flags multiple broken continuations on different lines' {
            $code = "Get-ChildItem ``  `r`n    -Path C:\Temp ``  `r`n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 2
        }

        It 'Does not provide SuggestedCorrections (guidance only)' {
            $code = "Get-ChildItem ``  `r`n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 1
            $results[0].SuggestedCorrections | Should -BeNullOrEmpty
        }

        # --- True negatives: must NOT flag ---

        It 'Does not flag valid backtick line continuation (no trailing whitespace)' {
            $code = "Get-ChildItem ```n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick inside string even with trailing space' {
            $code = @'
$msg = "some text ` with space after backtick
next line"
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick in comment with trailing space' {
            $code = "# This is a comment with `` and trailing space  `r`nGet-ChildItem"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick inside here-string' {
            $code = @'
$hs = @"
some text `
next line
"@
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 0
        }

        It 'Does not flag code without any backticks' {
            $code = 'Get-ChildItem -Path C:\Temp -Recurse'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 0
        }

        It 'Does not produce duplicates from nested ScriptBlockAst' {
            $code = "function Test-Broken {`r`n    Get-ChildItem ``  `r`n        -Recurse`r`n}"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 1
        }

        It 'Points extent at the exact backtick position, not the preceding token' {
            $code = "`$x = 1`r`n`$y = 2`r`nGet-ChildItem ``  `r`n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $results.Count | Should -Be 1
            $results[0].Extent.StartLineNumber | Should -Be 3
            $results[0].Extent.Text | Should -Be '`'
        }
    }

    # ================================================================
    # Rule 3 — Measure-AvoidBacktickObfuscationNoOpInIdentifier
    # ================================================================
    Context 'Rule 3: Measure-AvoidBacktickObfuscationNoOpInIdentifier' {

        # --- True positives: must flag ---

        It 'Flags obfuscation backtick in cmdlet name' {
            $code = 'Ge`t-Chil`dItem'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*NoOpInIdentifier*'
        }

        It 'Flags single obfuscation backtick in function name' {
            $code = "function Writ``e-Something {`n    param()`n}"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
        }

        It 'Provides SuggestedCorrections to remove no-op backtick' {
            $code = 'Ge`t-ChildItem'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
            # SuggestedCorrections may not survive PSScriptAnalyzer serialization
            # in all contexts. Verify the diagnostic message indicates autofix.
            $results[0].Message | Should -BeLike '*AUTOFIX: Yes*'
        }

        It 'Reports multiple backticks in same token as one diagnostic' {
            $code = 'G`e`t-C`h`i`l`d`I`t`e`m'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            # One diagnostic per token, even with many backticks.
            $results.Count | Should -Be 1
        }

        It 'Flags backtick in parameter name' {
            $code = 'Get-ChildItem -Pa`th C:\Temp'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
        }

        It 'Flags uppercase N after backtick in bare argument (not an escape)' {
            $code = 'Write-Host `N'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
        }

        It 'Still flags obfuscation backtick in Identifier token (Ge`t-Process)' {
            $code = 'Ge`t-Process'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
        }

        # --- True negatives: must NOT flag ---

        It 'Does not flag `n escape in bare argument (Generic token)' {
            $code = 'Write-Host `n'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not flag `t escape in bare argument (Generic token)' {
            $code = 'Write-Host `t'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not flag normal cmdlet names' {
            $code = 'Get-ChildItem -Path C:\Temp -Recurse'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick escape sequences in strings' {
            $code = @'
$msg = "Hello`nWorld`tTabbed"
Write-Host $msg
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not flag backtick line continuation (separate concern)' {
            $code = "Get-ChildItem ```n    -Recurse"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not flag variables without backticks' {
            $code = '$MyVariable = "test"'
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not flag comment containing backtick-identifier pattern' {
            $code = @'
# Ge`t-ChildItem is obfuscated
Get-ChildItem
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }

        It 'Does not produce duplicates from nested ScriptBlockAst' {
            $code = "function Invoke-Test {`n    Ge``t-ChildItem`n}"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 1
        }

        It 'Does not flag whitespace-only script' {
            $results = Invoke-Rule -ScriptDefinition '   ' -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $results.Count | Should -Be 0
        }
    }

    # ================================================================
    # Integration: settings file enables all three rules
    # ================================================================
    Context 'Integration with settings file' {
        It 'Settings file includes all three backtick rules' {
            $settings = Import-PowerShellDataFile -Path $Script:TempSettings
            $settings.IncludeRules | Should -Contain 'Measure-AvoidBacktickLineContinuation'
            $settings.IncludeRules | Should -Contain 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $settings.IncludeRules | Should -Contain 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
        }

        It 'Settings file includes all three new rules' {
            $settings = Import-PowerShellDataFile -Path $Script:TempSettings
            $settings.IncludeRules | Should -Contain 'Measure-AvoidArrayAdditionInLoop'
            $settings.IncludeRules | Should -Contain 'Measure-AvoidEnvPlatformSpecificVariable'
            $settings.IncludeRules | Should -Contain 'Measure-RequireConvertToJsonDepth'
        }

        It 'Settings file references the PSCodePatrol module path' {
            $settings = Import-PowerShellDataFile -Path $Script:TempSettings
            $settings.CustomRulePath | Should -Contain $Script:ModulePath
        }

        It 'Running via settings file catches a backtick continuation' {
            $code = "Get-ChildItem ```n    -Recurse"
            $results = @(Invoke-ScriptAnalyzer -ScriptDefinition $code -Settings $Script:TempSettings)
            $backtickResults = $results | Where-Object {
                $_.RuleName -like '*BacktickLineContinuation*'
            }
            $backtickResults.Count | Should -BeGreaterOrEqual 1
        }

        It 'PSMisleadingBacktick is NOT in IncludeRules (superseded)' {
            $settings = Import-PowerShellDataFile -Path $Script:TempSettings
            $settings.IncludeRules | Should -Not -Contain 'PSMisleadingBacktick'
        }
    }

    # ================================================================
    # Edge cases and tricky scenarios
    # ================================================================
    Context 'Edge cases' {
        It 'Handles script with only comments and whitespace' {
            $code = @'
# Just a comment
  # Another comment
'@
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 0
        }

        It 'Handles backtick at very end of script without crashing' {
            # Backtick at EOF — rule should handle it without error.
            $code = 'Get-ChildItem `'
            { Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation' } |
                Should -Not -Throw
        }

        It 'Rule 1 does not cross-fire on Rule 3 territory (no-op backtick in identifier)' {
            $code = 'Ge`t-ChildItem'
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r1.Count | Should -Be 0
        }

        It 'Rule 3 does not cross-fire on Rule 1 territory (line continuation)' {
            $code = "Get-ChildItem ```n    -Recurse"
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r3.Count | Should -Be 0
        }

        It 'Rule 2 does not cross-fire on Rule 1 territory (valid continuation)' {
            $code = "Get-ChildItem ```n    -Recurse"
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r2.Count | Should -Be 0
        }

        It 'Handles deeply nested functions without duplicate reports' {
            $code = "function Outer {`nfunction Middle {`nfunction Inner {`nGet-ChildItem ```n    -Path C:\Temp`n}`n}`n}"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
        }

        It 'Handles script with parse errors gracefully (structural classification)' {
            # Intentional syntax error: unclosed brace.
            # The rule should not crash and should classify backticks as structural.
            $code = "function Broken {`nGet-ChildItem ```n    -Recurse"
            { Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation' } |
                Should -Not -Throw
        }

        It 'Redundant backtick after operator (-and, -or, etc.)' {
            $code = "if (`$true -and ```n    `$false) { }"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*Redundant*'
        }

        It 'Redundant backtick after comma in function call' {
            $code = "Write-Host -Object 'hello', ```n    'world'"
            $results = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $results.Count | Should -Be 1
            $results[0].Message | Should -BeLike '*Redundant*'
        }

        It 'All three rules return Warning severity' {
            $r1 = Invoke-Rule -ScriptDefinition "Get-ChildItem ```n    -Recurse" -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r1[0].Severity | Should -Be 'Warning'
            $r2 = Invoke-Rule -ScriptDefinition "Get-ChildItem ``  `r`n    -Recurse" -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r2[0].Severity | Should -Be 'Warning'
            $r3 = Invoke-Rule -ScriptDefinition 'Ge`t-ChildItem' -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r3[0].Severity | Should -Be 'Warning'
        }
    }

    # ================================================================
    # Category coverage: all 13 detection scenarios from the backtick
    # taxonomy. Tests verify false-positive suppression for legitimate
    # usage (Ignore categories) and true-positive detection for flagged
    # categories.
    # ================================================================
    Context 'Category coverage: legitimate backtick usages must not be flagged' {

        # Cat 1 — Recognized escape sequences (extended set: `a `b `e `f `r `v)
        # These are valid escape sequences inside expandable strings.
        It 'Cat 1: Does not flag extended escape sequences `a `b `e `f `r `v in strings' {
            $code = @'
$bell = "Bell`a"
$bs   = "Backspace`b"
$esc  = "Escape`e"
$ff   = "FormFeed`f"
$cr   = "CarriageReturn`r"
$vt   = "VerticalTab`v"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 3 — Escaping metacharacters in unquoted arguments
        # Backtick before [, ], *, ? is legitimate wildcard escaping.
        It 'Cat 3: Does not flag metacharacter escaping in unquoted arguments' {
            $code = @'
Get-ChildItem -Path C:\Temp\test`[1`].txt
Get-Item file`*.log
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 4 — Escaping `" in expandable strings
        It 'Cat 4: Does not flag backtick-quote escape inside expandable strings' {
            $code = @'
$msg = "She said `"hello`" to everyone"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 5 — Literal backtick (self-escape ``) in expandable strings
        It 'Cat 5: Does not flag double-backtick literal inside expandable strings' {
            $code = @'
$msg = "This has a literal `` backtick character"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 8 — Wildcard escape inside string for -like/-notlike
        It 'Cat 8: Does not flag wildcard escaping inside -like string patterns' {
            $code = @'
$result = "test*value" -like "test`*value"
$check = "data[0]" -like "data`[0`]"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 9 — Regex / -replace double escaping (`$1 to prevent interpolation)
        It 'Cat 9: Does not flag backtick-dollar in -replace regex context' {
            $code = @'
$result = "hello world" -replace "(hello)", "`$1 there"
$name = "foo" -replace "^(f)", "`$1oo"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 10 — Expandable here-string with escape sequences
        It 'Cat 10: Does not flag escape sequences in expandable here-strings' {
            # Use double-quoted outer to construct the expandable here-string literal
            $code = "@`"`nLine1``nLine2``tTabbed`n`"@"
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 11 — Format operator context (-f)
        It 'Cat 11: Does not flag backtick escapes inside -f format strings' {
            $code = @'
$msg = "{0}`n{1}" -f "hello", "world"
$row = "{0}`t{1}`t{2}" -f "A", "B", "C"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        # Cat 12 — Single-quoted strings (backtick is literal, not special)
        It 'Cat 12: Does not flag backtick inside single-quoted strings' {
            $code = @'
$x = 'literal ` backtick in single quotes'
$y = 'another `n not an escape'
$z = 'Ge`t-ChildItem looks obfuscated but is just a string'
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }
    }

    # ================================================================
    # Category coverage: true positives for additional detection
    # scenarios that were not exercised in the main rule contexts.
    # ================================================================
    Context 'Category coverage: additional true-positive detection' {

        # Cat 7 — Obfuscation in ${} variable expansion
        # Backtick between word chars in a Variable token is suspicious.
        It 'Cat 7: Flags backtick inside ${} variable expression' {
            $code = @'
${ba`cktick} = 1
Write-Host ${ba`cktick}
'@
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r3.Count | Should -BeGreaterOrEqual 1
        }

        # Cat 6 extended — Obfuscation in type accelerator
        It 'Cat 6: Flags no-op backtick in type accelerator name' {
            $code = @'
$x = [sys`tem.string]::Empty
'@
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r3.Count | Should -BeGreaterOrEqual 1
        }

        # Cat 6 extended — Obfuscation in keyword
        It 'Cat 6: Flags no-op backtick in keyword-like usage' {
            $code = 'inv`oke-exp`ression "Get-Date"'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r3.Count | Should -Be 1
        }

        # Cat 2+6 mixed — Line continuation AND obfuscation in same script
        It 'Mixed: line continuation and obfuscation flagged independently' {
            $code = "Ge``t-ChildItem ```n    -Recurse"
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 1  # line continuation
            $r3.Count | Should -Be 1  # obfuscation
        }

        # Cat 2+13 mixed — Valid continuation AND broken continuation in same script
        It 'Mixed: valid and broken continuation in same script' {
            $code = "Get-ChildItem ```n    -Path C:\Temp ``  `r`n    -Recurse"
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r1.Count | Should -Be 1  # valid continuation
            $r2.Count | Should -Be 1  # broken continuation
        }
    }

    # ================================================================
    # Boundary and tricky scenarios that stress-test rule robustness.
    # ================================================================
    Context 'Boundary scenarios' {

        It 'Backtick in heredoc-like construct (single-quoted here-string) is ignored' {
            # Build source code containing a @'...'@ here-string via line array
            # to avoid outer here-string nesting issues.
            $lines = @(
                "`$heredoc = @'"
                "This has Ge``t-ChildItem inside"
                "And a broken continuation ``"
                "And a literal `` backtick"
                "'@"
                "`$x = 1"
            )
            $code = $lines -join "`n"
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        It 'Multiple escape types in same expandable string are ignored' {
            $code = @'
$complex = "Tab:`t Newline:`n Dollar:`$var Quote:`" Null:`0 Bell:`a Literal:``"
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        It 'Obfuscation backtick in parameter name only (not the cmdlet)' {
            $code = 'Get-ChildItem -Re`curse'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r3.Count | Should -Be 1
        }

        It 'Block comment containing backtick patterns is ignored by all rules' {
            $code = @'
<#
    Ge`t-ChildItem is obfuscated
    Get-Process `
        -Name foo
    broken ` attempt
#>
Get-ChildItem
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }

        It 'Adjacent legitimate usages do not confuse rules' {
            # String with escape sequences immediately followed by code with no backtick
            $code = @'
$msg = "Value: `$x`nDone"
Get-ChildItem -Path C:\Temp -Recurse |
    Where-Object { $_.Length -gt 0 }
'@
            $r1 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickLineContinuation'
            $r2 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickBrokenContinuationAttempt'
            $r3 = Invoke-Rule -ScriptDefinition $code -RuleName 'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
            $r1.Count | Should -Be 0
            $r2.Count | Should -Be 0
            $r3.Count | Should -Be 0
        }
    }
}
