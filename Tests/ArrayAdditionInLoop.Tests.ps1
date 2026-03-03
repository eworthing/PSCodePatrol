#Requires -Modules Pester, PSScriptAnalyzer

<#
.SYNOPSIS
    Tests for the Measure-AvoidArrayAdditionInLoop custom PSScriptAnalyzer rule.

.DESCRIPTION
    Validates that the rule detects += and equivalent ($var = $var + $item) accumulation
    inside loop bodies (foreach, for, while, do-while, do-until, ForEach-Object pipeline)
    and does NOT flag safe patterns: += outside loops, member-access/indexer LHS, numeric-
    constant RHS, or nested function definitions (scope boundary).
#>

BeforeAll {
    $Script:ScriptRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $Script:RulePath   = Join-Path $Script:ScriptRoot 'PSCodePatrol/PSCodePatrol.psm1'

    $Script:TempSettings = Join-Path ([IO.Path]::GetTempPath()) "pssa_arrayloop_$PID.psd1"
    @"
@{
    CustomRulePath = '$($Script:RulePath -replace "'","''")'
    IncludeRules   = @('Measure-AvoidArrayAdditionInLoop')
}
"@ | Set-Content -Path $Script:TempSettings -Encoding UTF8
}

AfterAll {
    if (Test-Path $Script:TempSettings) { Remove-Item $Script:TempSettings -Force }
}

Describe 'Measure-AvoidArrayAdditionInLoop' {

    # ── Should flag (unsafe patterns) ──

    Context 'flags += inside loops' {

        It 'flags $arr += inside foreach statement' {
            $script = @'
function Test-Fn {
    $results = @()
    foreach ($item in $collection) {
        $results += $item
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-AvoidArrayAdditionInLoop'
        }

        It 'flags += inside while loop' {
            $script = @'
function Test-Fn {
    $out = @()
    $i = 0
    while ($i -lt 10) {
        $out += $i
        $i++
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags += inside for loop' {
            $script = @'
function Test-Fn {
    $list = @()
    for ($i = 0; $i -lt 5; $i++) {
        $list += $i
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags += inside do-while loop' {
            $script = @'
function Test-Fn {
    $buf = @()
    $n = 0
    do {
        $buf += $n
        $n++
    } while ($n -lt 3)
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags += inside do-until loop' {
            $script = @'
function Test-Fn {
    $buf = @()
    $n = 0
    do {
        $buf += $n
        $n++
    } until ($n -ge 3)
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags multiple += in the same loop body' {
            $script = @'
function Test-Fn {
    $a = @()
    $b = @()
    foreach ($item in $collection) {
        $a += $item
        $b += $item.Name
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 2
        }

        It 'flags += in nested loop' {
            $script = @'
function Test-Fn {
    $out = @()
    foreach ($group in $groups) {
        foreach ($item in $group.Items) {
            $out += $item
        }
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags += at script level (outside function) inside foreach' {
            $script = @'
$results = @()
foreach ($item in Get-ChildItem) {
    $results += $item
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'includes variable name in diagnostic message' {
            $script = @'
function Test-Fn {
    $myAccumulator = @()
    foreach ($x in 1..5) {
        $myAccumulator += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Message | Should -BeLike '*myAccumulator*'
        }
    }

    # ── Should NOT flag (safe patterns) ──

    Context 'allows += outside loops' {

        It 'allows += in function body outside any loop' {
            $script = @'
function Test-Fn {
    $result = @()
    $result += Get-ChildItem
    $result += Get-Process
    return $result
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows += for simple string concatenation outside loop' {
            $script = @'
function Test-Fn {
    $msg = 'Hello'
    $msg += ' World'
    Write-Output $msg
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows += counter in script scope with no loop' {
            $script = @'
$count = 0
$count += 1
$count += 1
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'does not flag += in a nested function defined inside a loop' {
            # The inner function definition creates a scope boundary;
            # += inside it is not in loop scope.
            $script = @'
function Outer-Fn {
    foreach ($item in $collection) {
        function Inner-Fn {
            $local = @()
            $local += $item
            return $local
        }
        Inner-Fn
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows [List]::Add() pattern inside loop (preferred alternative)' {
            $script = @'
function Test-Fn {
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $collection) {
        $list.Add($item)
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows pipeline-collected foreach output (no +=)' {
            $script = @'
function Test-Fn {
    $results = foreach ($item in $collection) {
        [PSCustomObject]@{ Name = $item }
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── Message content ──

    Context 'diagnostic message' {

        It 'message contains O(n^2) performance guidance' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($x in 1..10) {
        $arr += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].Message | Should -BeLike '*O(n^2)*'
        }

        It 'message mentions immutable' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($x in 1..10) {
        $arr += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*immutable*'
        }

        It 'message mentions List alternative' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($x in 1..10) {
        $arr += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*List*'
        }

        It 'message mentions @(foreach) collect-output pattern' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($x in 1..10) {
        $arr += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*@(foreach*'
        }

        It 'message mentions StringBuilder for string concatenation' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($x in 1..10) {
        $arr += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r[0].Message | Should -BeLike '*StringBuilder*'
        }
    }

    # ── False-positive prevention ──

    Context 'does not flag safe in-loop patterns' {

        It 'allows $obj.Count += 1 inside loop (member access LHS)' {
            $script = @'
function Test-Fn {
    foreach ($item in $collection) {
        $obj.Count += 1
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $hash[''key''] += 1 inside loop (indexer LHS)' {
            $script = @'
function Test-Fn {
    $hash = @{}
    foreach ($item in $collection) {
        $hash['key'] += 1
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $counter += 1 inside loop (numeric integer constant RHS)' {
            $script = @'
function Test-Fn {
    $counter = 0
    foreach ($item in $collection) {
        $counter += 1
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $total += 2.5 inside loop (numeric decimal constant RHS)' {
            $script = @'
function Test-Fn {
    $total = 0
    foreach ($item in $collection) {
        $total += 2.5
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $i += $chunkSize in for-loop iterator (loop step, not accumulation)' {
            $script = @'
function Test-Fn {
    $chunkSize = 200
    for ($i = 0; $i -lt $items.Count; $i += $chunkSize) {
        $chunk = $items[$i..($i + $chunkSize - 1)]
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $total += $obj.Count when $total = 0 before loop (numeric accumulator)' {
            $script = @'
function Test-Fn {
    $total = 0
    foreach ($batch in $batches) {
        $total += $batch.Count
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows multiple numeric accumulators initialised before the same loop' {
            $script = @'
function Test-Fn {
    $processed = 0
    $succeeded = 0
    $failed = 0
    foreach ($batch in $batches) {
        $processed += $batch.totalCount
        $succeeded += $batch.syncedCount
        $failed    += $batch.failedCount
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $sum += $item.Value at script scope with $sum = 0 (no function)' {
            $script = @'
$sum = 0
foreach ($item in $data) {
    $sum += $item.Value
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $total += $x.Count when $total = $null before loop (null accumulator)' {
            $script = @'
function Test-Fn {
    $total = $null
    foreach ($x in $data) {
        $total += $x.Count
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'allows $total = $total + $x.Count when $total = $null (Pass 2 null accumulator)' {
            $script = @'
function Test-Fn {
    $total = $null
    foreach ($x in $data) {
        $total = $total + $x.Count
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'still flags $arr += $item when $arr = @() before loop (array, not numeric)' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($item in $collection) {
        $arr += $item
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }

    # ── ForEach-Object pipeline detection ──

    Context 'flags += inside ForEach-Object pipeline' {

        It 'flags += inside ForEach-Object { }' {
            $script = @'
$arr = @()
$collection | ForEach-Object { $arr += $_ }
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-AvoidArrayAdditionInLoop'
        }

        It 'flags += inside % { } (alias)' {
            $script = @'
$arr = @()
$c | % { $arr += $_ }
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'does not flag += in nested function inside ForEach-Object (scope boundary)' {
            $script = @'
$collection | ForEach-Object {
    function Inner {
        $a = @()
        $a += $x
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── Equivalent $var = $var + $item form ──

    Context 'flags $var = $var + $item inside loop' {

        It 'flags $arr = $arr + $item in foreach' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($item in $collection) {
        $arr = $arr + $item
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
            $r[0].RuleName | Should -Be 'Measure-AvoidArrayAdditionInLoop'
        }

        It 'flags $arr = $item + $arr (reverse order)' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($item in $collection) {
        $arr = $item + $arr
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $arr = $arr + $_ inside ForEach-Object' {
            $script = @'
$arr = @()
$collection | ForEach-Object { $arr = $arr + $_ }
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'does not flag $counter = $counter + 1 (numeric constant, O(1))' {
            $script = @'
function Test-Fn {
    $counter = 0
    foreach ($item in $collection) {
        $counter = $counter + 1
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'does not flag $counter = 1 + $counter (numeric constant, reversed)' {
            $script = @'
function Test-Fn {
    $counter = 0
    foreach ($item in $collection) {
        $counter = 1 + $counter
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'does not flag $arr = $other + $item (different variable)' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($item in $collection) {
        $arr = $other + $item
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }
    }

    # ── Non-constant RHS is still flagged ──

    Context 'flags non-constant RHS correctly' {

        It 'flags $arr += $item inside loop (variable RHS)' {
            $script = @'
function Test-Fn {
    $arr = @()
    foreach ($item in $collection) {
        $arr += $item
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $s = $s + $x.Name + '' '' inside loop (nested plus chain)' {
            $script = @'
function Test-Fn {
    $s = ''
    foreach ($x in $data) {
        $s = $s + $x.Name + ' '
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'flags $s = $s + $x.Name + $x.Suffix + ''-'' (deeper nested plus chain)' {
            $script = @'
function Test-Fn {
    $s = ''
    foreach ($x in $data) {
        $s = $s + $x.Name + $x.Suffix + '-'
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }

        It 'does not flag $total = $total + $x.A + $x.B when numeric accumulator' {
            $script = @'
function Test-Fn {
    $total = 0
    foreach ($x in $data) {
        $total = $total + $x.A + $x.B
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 0
        }

        It 'flags $str += $char inside loop (string concat is also O(n^2))' {
            $script = @'
function Test-Fn {
    $str = ''
    foreach ($char in $chars) {
        $str += $char
    }
}
'@
            $r = @(Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $Script:TempSettings)
            $r.Count | Should -Be 1
        }
    }
}
