@{
    Severity            = @('Error', 'Warning', 'Information')
    CustomRulePath      = @(
        './PSCodePatrol.psm1'
    )
    IncludeDefaultRules = $true
    IncludeRules        = @(
        # --- Default rules (always-on) ---
        'PSAvoidAssignmentToAutomaticVariable'
        'PSAvoidDefaultValueForMandatoryParameter'
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidGlobalAliases'
        'PSAvoidGlobalFunctions'
        'PSAvoidGlobalVars'
        'PSAvoidInvokingEmptyMembers'
        'PSAvoidMultipleTypeAttributes'
        'PSAvoidNullOrEmptyHelpMessageAttribute'
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSAvoidShouldContinueWithoutForce'
        'PSAvoidTrailingWhitespace'
        'PSAvoidUsingAllowUnencryptedAuthentication'
        'PSAvoidUsingBrokenHashAlgorithms'
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingComputerNameHardcoded'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingDeprecatedManifestFields'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingPositionalParameters'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingWMICmdlet'
        'PSAvoidUsingWriteHost'
        # PSMisleadingBacktick — superseded by Measure-AvoidBacktickBrokenContinuationAttempt
        'PSMissingModuleManifestField'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSPossibleIncorrectUsageOfRedirectionOperator'
        'PSProvideCommentHelp'
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSReviewUnusedParameter'
        'PSShouldProcess'
        'PSUseApprovedVerbs'
        # PSUseBOMForUnicodeEncodedFile — disabled: crashes PSScriptAnalyzer
        # on Windows CI when BOM is added to previously BOM-less files
        'PSUseCmdletCorrectly'
        'PSUseCompatibleTypes'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseLiteralInitializerForHashtable'
        'PSUseOutputTypeCorrectly'
        'PSUsePSCredentialType'
        'PSUseProcessBlockForPipelineCommand'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSUseSupportsShouldProcess'
        'PSUseToExportFieldsInManifest'
        'PSUseUTF8EncodingForHelpFile'
        'PSUseUsingScopeModifierInNewRunspaces'

        # --- Compatibility rules (require profile config in Rules) ---
        'PSUseCompatibleCommands'
        'PSUseCompatibleCmdlets'
        'PSUseCompatibleSyntax'

        # --- Opt-in rules (require Enable = $true in Rules) ---
        'PSAlignAssignmentStatement'
        'PSAvoidExclaimOperator'
        'PSAvoidLongLines'
        'PSAvoidSemicolonsAsLineTerminators'
        'PSAvoidUsingDoubleQuotesForConstantString'
        'PSPlaceCloseBrace'
        'PSPlaceOpenBrace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSUseCorrectCasing'

        # --- Project custom rules ---
        'Measure-AvoidDeepNesting'
        'Measure-UnsafeCountProperty'
        'Measure-AvoidBacktickLineContinuation'
        'Measure-AvoidBacktickBrokenContinuationAttempt'
        'Measure-AvoidBacktickObfuscationNoOpInIdentifier'
        'Measure-AvoidArrayAdditionInLoop'
        'Measure-AvoidEnvPlatformSpecificVariable'
        'Measure-RequireConvertToJsonDepth'
    )
    Rules               = @{
        # ── Profile discovery ──
        # To list installed compatibility-rule profiles on your system, run:
        #   Get-ChildItem "$((Get-Module PSScriptAnalyzer -ListAvailable).ModuleBase)/PSCompatibilityCollector/profiles"
        # The profile names below must match filenames (minus .json) in that folder.

        PSUseCompatibleSyntax                     = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.2')
        }
        PSUseCompatibleCommands                   = @{
            Enable         = $true
            TargetProfiles = @(
                'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'
            )
        }
        PSUseCompatibleCmdlets                    = @{
            compatibility = @(
                'desktop-5.1.14393.206-windows'
                'core-6.1.0-windows'
            )
        }
        PSAlignAssignmentStatement                = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSAvoidExclaimOperator                    = @{
            Enable = $true
        }
        PSAvoidLongLines                          = @{
            Enable            = $true
            MaximumLineLength = 120
        }
        PSAvoidSemicolonsAsLineTerminators        = @{
            Enable = $true
        }
        PSAvoidUsingDoubleQuotesForConstantString = @{
            Enable = $true
        }
        PSPlaceCloseBrace                         = @{
            Enable             = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
            NewLineAfter       = $true
        }
        PSPlaceOpenBrace                          = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSUseConsistentIndentation                = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }
        PSUseConsistentWhitespace                 = @{
            Enable         = $true
            CheckOpenBrace = $true
            CheckOpenParen = $true
            CheckOperator  = $false
            CheckSeparator = $true
        }
        PSUseCorrectCasing                        = @{
            Enable        = $true
            CheckCommands = $true
            CheckKeyword  = $true
            CheckOperator = $true
        }
    }
}
