<#
.SYNOPSIS
Writes a release's version into the files that name the library's version, which hold a placeholder in the repository.

.DESCRIPTION
The same script in every repository of the regex engines (keep the copies identical). The version is the tag's: v1.2.3
gives 1.2.3, and a harness release, harness-1.2.3.4, gives its library's 1.2.3 (a harness release is made only while the
library is unchanged since that tag). Each entry of the library package's stamp list in .github/release.json names a
file, the placeholder text, the text that replaces it ({version}, {major}, {minor} and {patch} are the version's), and
how many times the placeholder occurs there; a count that differs fails, so a moved or renamed placeholder cannot
release a file that still says it. Nothing is committed.

.PARAMETER Tag
The release's tag.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Tag,
    [string] $Config = '.github/release.json'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packages = @((Get-Content $Config -Raw | ConvertFrom-Json).packages)
$library = @($packages | Where-Object { -not $_.PSObject.Properties['harnessOf'] })
if ($library.Count -ne 1) { throw "$Config has $($library.Count) library packages; stamping expects one" }
$library = $library[0]
$harness = $packages | Where-Object { $_.PSObject.Properties['harnessOf'] } | Select-Object -First 1

$escaped = [regex]::Escape($library.tag)
if ($Tag -match "^$escaped(\d+)\.(\d+)\.(\d+)$") { }
elseif ($harness -and $Tag -match "^$([regex]::Escape($harness.tag))(\d+)\.(\d+)\.(\d+)\.\d+$") { }
else { throw "$Tag is neither $($library.tag)<major>.<minor>.<patch> nor a harness release of it" }
$major, $minor, $patch = $Matches[1], $Matches[2], $Matches[3]
$version = "$major.$minor.$patch"

foreach ($s in @($library.stamp)) {
    $text = [IO.File]::ReadAllText((Resolve-Path $s.file))
    # A placeholder spanning lines is written with \n; a file checked out with CRLF has \r\n.
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $placeholder = $s.placeholder.Replace("`n", $newline)
    $found = ([regex]::Matches($text, [regex]::Escape($placeholder))).Count
    if ($found -ne $s.count) { throw "$($s.file) has the placeholder '$($s.placeholder)' $found times, not $($s.count)" }
    $with = $s.with.Replace('{version}', $version).Replace('{major}', $major).Replace('{minor}', $minor).Replace('{patch}', $patch)
    [IO.File]::WriteAllText((Resolve-Path $s.file), $text.Replace($placeholder, $with.Replace("`n", $newline)))
    Write-Host "$($s.file): '$($s.placeholder)' -> '$with' ($found)"
}
