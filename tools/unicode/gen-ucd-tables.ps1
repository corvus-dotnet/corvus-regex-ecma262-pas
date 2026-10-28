<#
.SYNOPSIS
    Writes src/Corvus.Ecma262.RegularExpressions.Ucd<major>.pas, the unit of the Unicode data of one version of
    Unicode for the engine.

.DESCRIPTION
    The engine takes every Unicode property it reads from the tables this script writes, and nothing from the
    run-time library of the compiler, so that its answers do not depend on the compiler that built it.

    The data comes from tables<major>.rs of the corvus-regex-ecma262 Rust crate, which holds the same Unicode data as
    every other engine. The engine carries Unicode 13, 17 and 18, a unit for each with the same names inside, whose
    FillUcd<major> copies its tables into a TUcdData for the Ucd unit. The unit includes the version's properties of
    strings, Corvus.Ecma262.RegularExpressions.Strings<major>.inc, which tools/unicode/gen-strings.ps1 writes. Each table there is written here under the same name in Pascal's case (GC_LU is GcLu,
    SCX_GREEK is ScxGreek), with the same ranges: the ones up to U+FFFF as UInt16 and the rest as UInt32. The crate
    already writes a table once and names it wherever it is used again, so this script does too.

    Pascal has no case statement over strings that Delphi also compiles, so each lookup of a table by name is written
    as two arrays, the names in ordinal order and the number of the table of each, which the unit searches.

.PARAMETER CrateTables
    The path of corvus-regex-ecma262/src/tables<major>.rs in a checkout of the Rust crate.

.PARAMETER Output
    The file to write. The default is src/Corvus.Ecma262.RegularExpressions.Ucd<major>.pas of this repository, for
    the major number of the version of Unicode of the source.

.PARAMETER Check
    Compares what would be written with the file in place and writes nothing. The script fails when they differ, so
    CI can tell that the tables are the crate's.

.EXAMPLE
    pwsh tools/unicode/gen-ucd-tables.ps1 -CrateTables ../corvus-regex-ecma262-rs/corvus-regex-ecma262/src/tables17.rs
#>
param(
    [Parameter(Mandatory = $true)][string]$CrateTables,
    [string]$Output = '',
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$source = [System.IO.File]::ReadAllText((Resolve-Path $CrateTables))

function Find([string]$pattern, [string]$what) {
    $m = [regex]::Match($source, $pattern, 'Singleline')
    if (-not $m.Success) { throw "the crate's tables have no $what. The generator needs updating for the crate's file." }
    return $m
}

function Get-PascalName([string]$rustName) {
    $parts = @($rustName.ToLowerInvariant().Split('_') | Where-Object { $_ -ne '' } |
            ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })
    return $parts -join ''
}

function Get-Numbers([string]$text) {
    return , @([regex]::Matches($text, '0x[0-9A-Fa-f]+|\d+') | ForEach-Object { [Convert]::ToInt64($_.Value, $(if ($_.Value.StartsWith('0x')) { 16 } else { 10 })) })
}

$version = (Find 'pub\(crate\) const VERSION: &str = "([^"]+)";' 'VERSION').Groups[1].Value
$major = $version.Split('.')[0]
$unit = "Corvus.Ecma262.RegularExpressions.Ucd$major"
if (-not $Output) { $Output = Join-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src') "$unit.pas" }
$sourceName = Split-Path $CrateTables -Leaf

$out = [System.Text.StringBuilder]::new()
function Add-Line([string]$line = '') { [void]$out.Append($line).Append("`n") }

# Writes items separated by commas, in rows no longer than a line of the package may be.
function Add-Wrapped([string]$indent, [string[]]$items) {
    $row = [System.Text.StringBuilder]::new($indent)
    for ($k = 0; $k -lt $items.Count; $k++) {
        $item = $items[$k]
        if ($k -lt $items.Count - 1) { $item += ',' }
        if ($row.Length -gt $indent.Length -and $row.Length + 1 + $item.Length -gt 118) {
            Add-Line $row.ToString()
            $row = [System.Text.StringBuilder]::new($indent)
        }
        if ($row.Length -gt $indent.Length) { [void]$row.Append(' ') }
        [void]$row.Append($item)
    }
    if ($row.Length -gt $indent.Length) { Add-Line $row.ToString() }
}

function Add-Values([string]$name, [string]$type, $values) {
    Add-Line "  $($name): array[0..$($values.Count - 1)] of $type = ("
    for ($k = 0; $k -lt $values.Count; $k += 12) {
        $last = [Math]::Min($k + 12, $values.Count) - 1
        $row = @($values[$k..$last] | ForEach-Object { '${0:X}' -f $_ })
        $end = if ($last -eq $values.Count - 1) { '' } else { ',' }
        Add-Line ('    ' + ($row -join ', ') + $end)
    }
    Add-Line '  );'
}

# The tables, in the crate's order.
$order = [System.Collections.Generic.List[object]]::new()
$identifiers = @{}
$body = [System.Text.StringBuilder]::new()
$header = $out
$out = $body
foreach ($m in [regex]::Matches($source, 'pub\(super\) static (\w+): Table = Table \{(.*?)\n\};', 'Singleline')) {
    $name = Get-PascalName $m.Groups[1].Value
    # Pascal does not tell names apart by case.
    if ($identifiers.ContainsKey($name.ToLowerInvariant())) { throw "Two tables would be named $name." }
    $identifiers[$name.ToLowerInvariant()] = $true
    $r16 = [regex]::Match($m.Groups[2].Value, 'r16: &\[(.*?)\]', 'Singleline')
    $r32 = [regex]::Match($m.Groups[2].Value, 'r32: &\[(.*?)\]', 'Singleline')
    $low = if ($r16.Success) { Get-Numbers $r16.Groups[1].Value } else { @() }
    $high = if ($r32.Success) { Get-Numbers $r32.Groups[1].Value } else { @() }
    if (($low.Count % 2) -ne 0 -or ($high.Count % 2) -ne 0) { throw "Table $name has an odd number of bounds." }
    $order.Add(@{ Rust = $m.Groups[1].Value; Name = $name; Low = ($low.Count -gt 0); High = ($high.Count -gt 0) })
    if ($low.Count -gt 0) { Add-Values "${name}R16" 'UInt16' $low }
    if ($high.Count -gt 0) { Add-Values "${name}R32" 'UInt32' $high }
    Add-Line
}
$pascalOf = @{}
foreach ($t in $order) { $pascalOf[$t.Rust] = $t.Name }

function Add-CaseTable([string]$pascalName, [string]$rustName) {
    $m = Find ("pub\(super\) static " + $rustName + ": &\[CaseRange\] = &\[(.*?)\n\];") $rustName
    $rows = @([regex]::Matches($m.Groups[1].Value, 'CaseRange \{ first: (-?\w+), delta: (-?\w+), length: (\w+), mask: (\w+) \}'))
    Add-Line "  $($pascalName): array[0..$($rows.Count - 1)] of TUcdCaseRange = ("
    for ($k = 0; $k -lt $rows.Count; $k++) {
        $row = $rows[$k]
        $first = [Convert]::ToInt32($row.Groups[1].Value, 16)
        $end = if ($k -eq $rows.Count - 1) { '' } else { ',' }
        Add-Line (('    (First: ${0:X}; Delta: {1}; Length: {2}; Mask: {3})' -f $first, $row.Groups[2].Value, $row.Groups[3].Value, $row.Groups[4].Value) + $end)
    }
    Add-Line '  );'
    Add-Line
}

Add-Line '  { CaseFolds is the simple case folding (the C and S rows of CaseFolding.txt). Each row is the first code point of a'
Add-Line '    range, the amount to add, the length of the range, and a mask. The amount applies to the code points whose offset'
Add-Line '    in the range has none of the bits of the mask. }'
Add-CaseTable 'CaseFolds' 'CASE_FOLDS'
Add-Line '  { UpperCases is the simple uppercase mapping, in the form of CaseFolds. }'
Add-CaseTable 'UpperCases' 'UPPER_CASES'

# Writes the lookup of a table by name, from a match of the crate: the names in ordinal order, and the number of the
# table of each.
function Add-Lookup([string]$rustFn, [string]$prefix, [string]$comment) {
    $m = Find ("pub\(super\) fn " + $rustFn + "\(name: &str\) -> Option<&'static Table> \{\s*match name \{(.*?)\n\s*_ => None,") $rustFn
    $pairs = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($arm in [regex]::Matches($m.Groups[1].Value, '((?:"[^"]*"\s*\|?\s*)+)=> Some\(&(\w+)\)')) {
        $target = $pascalOf[$arm.Groups[2].Value]
        if ($null -eq $target) { throw "$rustFn names $($arm.Groups[2].Value), which is not a table." }
        foreach ($n in [regex]::Matches($arm.Groups[1].Value, '"([^"]*)"')) { $pairs.Add($n.Groups[1].Value, $target) }
    }
    $lines = @($comment -split "`n")
    for ($k = 0; $k -lt $lines.Count; $k++) {
        $open = if ($k -eq 0) { '  { ' } else { '    ' }
        $close = if ($k -eq $lines.Count - 1) { ' }' } else { '' }
        Add-Line ($open + $lines[$k] + $close)
    }
    Add-Line "  $($prefix)Names: array[0..$($pairs.Count - 1)] of UTF8String = ("
    Add-Wrapped '    ' @($pairs.Keys | ForEach-Object { "'$_'" })
    Add-Line '  );'
    Add-Line "  $($prefix)Tables: array[0..$($pairs.Count - 1)] of Int32 = ("
    Add-Wrapped '    ' @($pairs.Values)
    Add-Line '  );'
    Add-Line
}

$out = $header
Add-Line "unit $unit;"
Add-Line '{$I ecma262.inc}'
Add-Line
Add-Line "{ Code generated by tools/unicode/gen-ucd-tables.ps1 from $sourceName of the corvus-regex-ecma262 Rust crate, which"
Add-Line "  holds the Unicode $version property tables of every engine. DO NOT EDIT. }"
Add-Line
Add-Line 'interface'
Add-Line
Add-Line 'uses'
Add-Line '  Corvus.Ecma262.RegularExpressions.Ucd;'
Add-Line
Add-Line "{ FillUcd$major copies the tables of Unicode $version, their lookups by name, the names of the scripts and of the binary"
Add-Line '  properties, the case mappings and the properties of strings into D. }'
Add-Line "procedure FillUcd$major(var D: TUcdData);"
Add-Line
Add-Line 'implementation'
Add-Line
Add-Line 'var'
Add-Line '  { Target is the TUcdData that FillUcd fills, which Load16 and Load32 write to. }'
Add-Line '  Target: PUcdData;'
Add-Line
Add-Line 'procedure Load16(Table: Int32; const Ranges: array of UInt16);'
Add-Line 'var'
Add-Line '  I: Int32;'
Add-Line 'begin'
Add-Line '  SetLength(Target^.Tables[Table].R16, Length(Ranges));'
Add-Line '  for I := 0 to High(Ranges) do'
Add-Line '    Target^.Tables[Table].R16[I] := Ranges[I];'
Add-Line 'end;'
Add-Line
Add-Line 'procedure Load32(Table: Int32; const Ranges: array of UInt32);'
Add-Line 'var'
Add-Line '  I: Int32;'
Add-Line 'begin'
Add-Line '  SetLength(Target^.Tables[Table].R32, Length(Ranges));'
Add-Line '  for I := 0 to High(Ranges) do'
Add-Line '    Target^.Tables[Table].R32[I] := Ranges[I];'
Add-Line 'end;'
Add-Line
Add-Line 'const'
Add-Line '  { TablesVersion is the version of Unicode the tables hold. }'
Add-Line "  TablesVersion = '$version';"
Add-Line
Add-Line '  { TableCount is the number of tables. Each constant below numbers one of them. }'
Add-Line "  TableCount = $($order.Count);"
for ($k = 0; $k -lt $order.Count; $k++) { Add-Line "  $($order[$k].Name) = $k;" }
Add-Line
Add-Lookup 'category_table' 'CategoryTable' 'CategoryTable holds the table of each General_Category value that is not a group, by any of its names.'
Add-Lookup 'binary_table' 'BinaryTable' 'BinaryTable holds the table of each binary property, by its canonical name.'
Add-Lookup 'script_table' 'ScriptTable' "ScriptTable holds the table of each Script value other than Unknown, by its long name and by each alias (the ISO`n15924 code, for example)."
Add-Lookup 'script_extensions_table' 'ScriptExtensionsTable' "ScriptExtensionsTable holds the table of each Script_Extensions value other than Unknown. It is the table of the`nScript value when the two have the same ranges."

$names = (Find 'pub\(super\) static SCRIPT_NAMES: &\[&\[&str\]\] = &\[(.*?)\n\];' 'SCRIPT_NAMES').Groups[1].Value
$flat = [System.Collections.Generic.List[string]]::new()
$firsts = [System.Collections.Generic.List[string]]::new()
$scriptCount = 0
foreach ($row in [regex]::Matches($names, '&\[([^\]]*)\]')) {
    $firsts.Add([string]$flat.Count)
    foreach ($n in [regex]::Matches($row.Groups[1].Value, '"([^"]*)"')) { $flat.Add("'$($n.Groups[1].Value)'") }
    $scriptCount++
}
$firsts.Add([string]$flat.Count)
Add-Line '  { ScriptNameList lists every name of every script, the long name of each followed by its aliases. The names of'
Add-Line '    script K are the elements ScriptNameFirst[K] to ScriptNameFirst[K + 1] - 1. }'
Add-Line "  ScriptCount = $scriptCount;"
Add-Line "  ScriptNameList: array[0..$($flat.Count - 1)] of UTF8String = ("
Add-Wrapped '    ' $flat.ToArray()
Add-Line '  );'
Add-Line "  ScriptNameFirst: array[0..$scriptCount] of Int32 = ("
Add-Wrapped '    ' $firsts.ToArray()
Add-Line '  );'
Add-Line
$binary = @([regex]::Matches((Find 'pub\(super\) static BINARY_NAMES: &\[&str\] = &\[(.*?)\n\];' 'BINARY_NAMES').Groups[1].Value, '"([^"]*)"') |
        ForEach-Object { "'$($_.Groups[1].Value)'" })
Add-Line '  { BinaryNameList lists the canonical name of every binary property that has a table. }'
Add-Line "  BinaryNameList: array[0..$($binary.Count - 1)] of UTF8String = ("
Add-Wrapped '    ' $binary
Add-Line '  );'
Add-Line
[void]$out.Append($body.ToString())

Add-Line '{ LoadTables copies the ranges of every table into the tables of Target. }'
Add-Line 'procedure LoadTables;'
Add-Line 'begin'
foreach ($table in $order) {
    if ($table.Low) { Add-Line "  Load16($($table.Name), $($table.Name)R16);" }
    if ($table.High) { Add-Line "  Load32($($table.Name), $($table.Name)R32);" }
}
Add-Line 'end;'
Add-Line
Add-Line "{`$I Corvus.Ecma262.RegularExpressions.Strings$major.inc}"
Add-Line
Add-Line "procedure FillUcd$major(var D: TUcdData);"
Add-Line 'var'
Add-Line '  I, K: Int32;'
Add-Line 'begin'
Add-Line '  D.Version := TablesVersion;'
Add-Line '  SetLength(D.Tables, TableCount);'
Add-Line '  Target := @D;'
Add-Line '  LoadTables;'
Add-Line '  Target := nil;'
Add-Line '  UcdCopyLookup(CategoryTableNames, CategoryTableTables, D.Category);'
Add-Line '  UcdCopyLookup(BinaryTableNames, BinaryTableTables, D.Binary);'
Add-Line '  UcdCopyLookup(ScriptTableNames, ScriptTableTables, D.Script);'
Add-Line '  UcdCopyLookup(ScriptExtensionsTableNames, ScriptExtensionsTableTables, D.ScriptExtensions);'
Add-Line '  SetLength(D.ScriptNameLists, ScriptCount);'
Add-Line '  for I := 0 to ScriptCount - 1 do begin'
Add-Line '    SetLength(D.ScriptNameLists[I], ScriptNameFirst[I + 1] - ScriptNameFirst[I]);'
Add-Line '    for K := ScriptNameFirst[I] to ScriptNameFirst[I + 1] - 1 do'
Add-Line '      D.ScriptNameLists[I][K - ScriptNameFirst[I]] := ScriptNameList[K];'
Add-Line '  end;'
Add-Line '  UcdCopyNames(BinaryNameList, D.BinaryNames);'
Add-Line '  UcdCopyCases(CaseFolds, D.CaseFolds);'
Add-Line '  UcdCopyCases(UpperCases, D.UpperCases);'
Add-Line '  UcdCopyNames(StringPropertyNames, D.StringNames);'
Add-Line '  UcdCopyNames(StringPropertyPoints, D.StringPoints);'
Add-Line '  UcdCopyNames(StringPropertySequences, D.StringSequences);'
Add-Line 'end;'
Add-Line
Add-Line 'end.'

$text = $out.ToString().TrimEnd("`n")
foreach ($line in $text -split "`n") {
    if ($line.Length -gt 120) { throw "A line of the output is longer than 120 characters: $line" }
}
if ($Check) {
    $current = if (Test-Path $Output) { [System.IO.File]::ReadAllText($Output) } else { '' }
    if ($current -ne $text) { throw "$Output is not what $CrateTables generates. Run tools/unicode/gen-ucd-tables.ps1." }
    Write-Host "$Output is current ($($order.Count) tables)."
    return
}
# The file ends without a line break, as every file of the package does.
[System.IO.File]::WriteAllText($Output, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $Output with $($order.Count) tables, Unicode $version."
