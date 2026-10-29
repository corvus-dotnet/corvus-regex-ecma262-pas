<#
.SYNOPSIS
    Writes docs/api.md, the API reference the documentation site publishes, from the interface of
    src/Corvus.Ecma262.RegularExpressions.pas.

.DESCRIPTION
    Every declaration of the unit's interface, in its order, with the comment written above it: the constants, the
    types (a record or an interface without its private part) and the functions, overloads together. A type the unit
    takes from another unit of the library (the exceptions) has that unit's comment.

.PARAMETER Check
    Compares what would be written with docs/api.md and writes nothing. The script fails when they differ.
#>
param([switch] $Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$unitPath = Join-Path $root 'src' 'Corvus.Ecma262.RegularExpressions.pas'
$out = Join-Path $root 'docs' 'api.md'

function Get-Interface([string]$path) {
    $text = [System.IO.File]::ReadAllText($path) -replace "`r", ''
    $m = [regex]::Match($text, '(?ms)^interface\n(.*?)^implementation\n')
    if (-not $m.Success) { throw "$path has no interface section." }
    return $m.Groups[1].Value
}

# The comment text of a block of comment lines: the braces and the (* *) taken off, dedented, joined as paragraphs.
function Get-CommentText([string[]]$lines) {
    $text = ($lines -join "`n").Trim()
    $text = $text -replace '^\(\*\s?', '' -replace '\s?\*\)$', '' -replace '^\{\s?', '' -replace '\s?\}$', ''
    $paragraphs = ($text -split "\n\s*\n") | ForEach-Object { (($_ -split "`n") | ForEach-Object { $_.Trim() }) -join ' ' }
    return ($paragraphs -join "`n`n").Trim()
}

# The declarations of an interface section, each with the comment above it.
function Get-Declarations([string]$section) {
    $lines = $section -split "`n"
    $items = [System.Collections.Generic.List[object]]::new()
    $comment = @()
    $inComment = $false
    $kind = 'none'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trim = $line.Trim()
        if ($inComment) {
            $comment += $line
            if ($trim.EndsWith('}') -or $trim.EndsWith('*)')) { $inComment = $false }
            continue
        }
        if ($trim -eq '') { continue }
        if ($trim -match '^(\{|\(\*)') {
            $comment = @($line)
            $inComment = -not ($trim.EndsWith('}') -or $trim.EndsWith('*)'))
            continue
        }
        if ($trim -match '^uses\b') { while (-not $lines[$i].Trim().EndsWith(';')) { $i++ }; $comment = @(); continue }
        if ($trim -in @('type', 'const')) { $kind = $trim; $comment = @(); continue }
        if ($line -match '^(function|procedure) (\w+)') {
            $name = $Matches[2]
            $decl = @($line)
            while (-not ($decl[-1].TrimEnd().EndsWith(';') -and (($decl -join ' ').Split('(').Count -eq ($decl -join ' ').Split(')').Count))) { $i++; $decl += $lines[$i] }
            $items.Add([pscustomobject]@{ Section = 'Functions'; Name = $name; Code = ($decl -join "`n"); Doc = (Get-CommentText $comment) })
            $comment = @()
            continue
        }
        if ($line -match '^  (\w+) = (.*)$') {
            $name = $Matches[1]
            $rest = $Matches[2]
            $decl = @($line.Substring(2))
            if ($rest -match '^(record|interface)\b' -and -not $rest.TrimEnd().EndsWith(';')) {
                $private = $false
                do {
                    $i++
                    $l = $lines[$i]
                    if ($l -match '^\s*(private|strict private)\s*$') { $private = $true; continue }
                    if ($l -match '^\s*public\s*$') { $private = $false; continue }
                    if ($l -match "^\s*\['\{") { continue }
                    if (-not $private) { $decl += $l.Substring([Math]::Min(2, $l.Length)) }
                } while ($lines[$i] -notmatch '^  end;')
            }
            $section = if ($kind -eq 'const') { 'Constants' } else { 'Types' }
            $items.Add([pscustomobject]@{ Section = $section; Name = $name; Code = ($decl -join "`n"); Doc = (Get-CommentText $comment) })
            $comment = @()
            continue
        }
        $comment = @()
    }
    return $items
}

$items = Get-Declarations (Get-Interface $unitPath)

# A type taken from another unit of the library has that unit's comment.
$other = @{}
foreach ($file in Get-ChildItem (Join-Path $root 'src') -Filter 'Corvus.Ecma262.RegularExpressions.*.pas') {
    try { foreach ($d in Get-Declarations (Get-Interface $file.FullName)) { $other[$d.Name] = $d } } catch { }
}
foreach ($item in $items) {
    if (-not $item.Doc -and $item.Code -match '= Corvus\.Ecma262\.RegularExpressions\.\w+\.(\w+);$' -and $other.ContainsKey($Matches[1])) {
        $item.Doc = $other[$Matches[1]].Doc
    }
}

$sb = [System.Text.StringBuilder]::new()
function Add([string]$line = '') { [void]$sb.Append($line).Append("`n") }
Add '# API reference'
Add
Add 'The interface of `Corvus.Ecma262.RegularExpressions`, generated from its declarations and their comments by'
Add '`tools/docs/gen-api.ps1`. [Getting started](getting-started.md) shows it at work.'
foreach ($section in 'Constants', 'Types', 'Functions') {
    $group = @($items | Where-Object Section -eq $section)
    if ($group.Count -eq 0) { continue }
    Add
    Add "## $section"
    # Overloads, and a forward declaration with its type, are one entry.
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $group) {
        if ($seen.Contains($item.Name)) { continue }
        $seen.Add($item.Name)
        $same = @($group | Where-Object Name -eq $item.Name | Where-Object { -not ($_.Code -match '= interface;$') })
        if ($same.Count -eq 0) { continue }
        Add
        Add "### $($item.Name)"
        Add
        Add '```pascal'
        Add (($same | ForEach-Object Code) -join "`n")
        Add '```'
        $doc = (@($group | Where-Object Name -eq $item.Name | ForEach-Object Doc | Where-Object { $_ }) -join "`n`n")
        if ($doc) { Add; Add $doc }
    }
}
$text = $sb.ToString().TrimEnd("`n") + "`n"

if ($Check) {
    $current = if (Test-Path $out) { [System.IO.File]::ReadAllText($out) } else { '' }
    if ($current -ne $text) { throw 'docs/api.md is not what the unit''s interface makes: run tools/docs/gen-api.ps1.' }
    Write-Host 'docs/api.md is current.'
    return
}
[System.IO.File]::WriteAllText($out, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote docs/api.md: $($items.Count) declarations."
