function New-ScriptExtentFromOffset {
    <#
    .SYNOPSIS
        Creates an IScriptExtent from a character offset and length within script text.
    .DESCRIPTION
        Builds a line-starts array via a single O(n) scan, then maps the start and
        end offsets to 1-based line/column positions. Returns a ScriptExtent with
        accurate Text, StartLineNumber, and StartColumnNumber properties.
    #>
    param(
        [string]$Text,
        [int]$Offset,
        [int]$Length,
        [string]$FilePath = ''
    )

    # Build line-starts array: index of the first character of each line.
    $lineStarts = [System.Collections.Generic.List[int]]::new()
    $lineStarts.Add(0)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq [char]"`n") {
            $lineStarts.Add($i + 1)
        }
    }

    # Resolve start offset to line number and column.
    $startLineIdx = 0
    for ($i = $lineStarts.Count - 1; $i -ge 0; $i--) {
        if ($lineStarts[$i] -le $Offset) {
            $startLineIdx = $i
            break
        }
    }
    $startLineNumber   = $startLineIdx + 1
    $startColumnNumber = $Offset - $lineStarts[$startLineIdx] + 1

    # Resolve end offset to line number and column.
    $endOffset  = $Offset + $Length
    $endLineIdx = 0
    for ($i = $lineStarts.Count - 1; $i -ge 0; $i--) {
        if ($lineStarts[$i] -le $endOffset) {
            $endLineIdx = $i
            break
        }
    }
    $endLineNumber   = $endLineIdx + 1
    $endColumnNumber = $endOffset - $lineStarts[$endLineIdx] + 1

    # Extract line text (strip trailing line endings for ScriptPosition).
    $startLineEnd  = if ($startLineIdx + 1 -lt $lineStarts.Count) { $lineStarts[$startLineIdx + 1] } else { $Text.Length }
    $startLineText = $Text.Substring($lineStarts[$startLineIdx], $startLineEnd - $lineStarts[$startLineIdx]) -replace '\r?\n$', ''

    $endLineEnd  = if ($endLineIdx + 1 -lt $lineStarts.Count) { $lineStarts[$endLineIdx + 1] } else { $Text.Length }
    $endLineText = $Text.Substring($lineStarts[$endLineIdx], $endLineEnd - $lineStarts[$endLineIdx]) -replace '\r?\n$', ''

    # Construct ScriptPosition then ScriptExtent.
    $posType  = [System.Management.Automation.Language.ScriptPosition]
    $extType  = [System.Management.Automation.Language.ScriptExtent]
    $startPos = $posType::new($FilePath, $startLineNumber, $startColumnNumber, $startLineText)
    $endPos   = $posType::new($FilePath, $endLineNumber,   $endColumnNumber,   $endLineText)

    return $extType::new($startPos, $endPos)
}
