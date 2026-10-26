<#
.SYNOPSIS
Releases, after a merge, each package of .github/release.json whose paths changed since its last tag.

.DESCRIPTION
The same script in every repository of the regex engines (keep the copies identical). For each package it finds the
last tag of the package's prefix; if the package's paths changed between that tag and the merge, the package is
released with the next version: the last one with the patch raised by one, or the package's nextVersion where that is
higher (a pull request that needs a minor or major version edits nextVersion). A package with harnessOf is a harness
image whose tags are harness-<version of its library>.<n>: it is released only when its library is not, since a
release of the library publishes the image too.

A release is a published GitHub release whose tag is created on the merge commit, made with the token in GH_TOKEN. That
must be the endjin bot's: a release made with the workflow's own token starts no other workflow, and the publishing
workflows run on the release. The notes are the pull requests merged since the last tag that touched the package. A
package with stampedTag is tagged on a commit of the merge with its version written in (stamp.ps1), for a registry that
builds from the tag's source.

.PARAMETER Sha
The merge commit. The history and the tags must have been fetched.

.PARAMETER DryRun
Writes what would be released, and makes nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Sha,
    [string] $Config = '.github/release.json',
    [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Tags([string] $Prefix, [string] $Pattern) {
    # The package's tags, oldest version first, as objects of the tag and its version.
    @(git tag --list "$Prefix*" | ForEach-Object {
        if ($_ -match "^$([regex]::Escape($Prefix))($Pattern)$") { [pscustomobject]@{ Tag = $_; Version = [version]$Matches[1] } }
    } | Sort-Object Version)
}

function Get-Base([string] $Tag) {
    # Where the release tagged $Tag was made from on main: the tag itself, or, for a package released as a stamped
    # commit (stampedTag), that commit's parent, the merge it was made on; the stamped files would otherwise always differ.
    git merge-base --is-ancestor $Tag $Sha
    if ($LASTEXITCODE -eq 0) { $Tag } else { "$Tag^" }
}

function Test-Changed([string] $From, [string[]] $Paths) {
    $From = Get-Base $From
    git diff --quiet $From $Sha -- @Paths
    if ($LASTEXITCODE -gt 1) { throw "git diff failed between $From and $Sha" }
    $LASTEXITCODE -eq 1
}

function Get-Notes([string] $From, [string[]] $Paths) {
    # The pull requests merged since $From that touched the paths: the first-parent commits of main between the two,
    # each asked for its pull request.
    $range = if ($From) { "$(Get-Base $From)..$Sha" } else { $Sha }
    $lines = foreach ($commit in @(git log --first-parent --format=%H $range -- @Paths)) {
        $pr = gh api "repos/$env:GITHUB_REPOSITORY/commits/$commit/pulls" --jq '[.[] | select(.merged_at != null)][0] | select(. != null) | "- \(.title) (#\(.number))"' 2>$null
        if (-not $LASTEXITCODE -and $pr) { $pr } else { "- $(git log -1 --format=%s $commit) ($($commit.Substring(0, 7)))" }
    }
    if (-not $lines) { $lines = @('- No pull request: the changes were made before the last release.') }
    "## Changes`n`n$(@($lines) -join "`n")"
}

$packages = @((Get-Content $Config -Raw | ConvertFrom-Json).packages)
$released = @{}
$plan = foreach ($p in $packages | Sort-Object { [bool]$_.PSObject.Properties['harnessOf'] }) {
    if ($p.PSObject.Properties['harnessOf']) {
        $library = $packages | Where-Object name -eq $p.harnessOf
        if ($released.ContainsKey($library.name)) { continue }
        $libraryTags = Get-Tags $library.tag '\d+\.\d+\.\d+'
        if (-not $libraryTags) { continue }
        $base = $libraryTags[-1]
        $prefix = "$($p.tag)$($base.Version)."
        $numbers = @(git tag --list "$prefix*" | Where-Object { $_ -match "^$([regex]::Escape($prefix))(\d+)$" } |
            ForEach-Object { [int]$Matches[1] } | Sort-Object)
        $last = if ($numbers) { "$prefix$($numbers[-1])" } else { $base.Tag }
        if (-not (Test-Changed $last @($p.paths))) { continue }
        $n = if ($numbers) { $numbers[-1] + 1 } else { 1 }
        $version = "$($base.Version).$n"
    }
    else {
        $tags = Get-Tags $p.tag '\d+\.\d+\.\d+'
        $next = if ($p.PSObject.Properties['nextVersion']) { [version]$p.nextVersion } else { $null }
        if ($tags) {
            $last = $tags[-1].Tag
            if (-not (Test-Changed $last @($p.paths))) { continue }
            $v = $tags[-1].Version
            $version = [version]::new($v.Major, $v.Minor, $v.Build + 1)
            if ($next -and $next -gt $version) { $version = $next }
        }
        else {
            if (-not $next) { throw "$($p.name) has no tag and no nextVersion to start from" }
            $last = $null
            $version = $next
        }
        $released[$p.name] = $true
    }
    $tag = "$($p.tag)$version"
    if (git tag --list $tag) { Write-Host "$tag exists: already released"; continue }
    $harness = [bool]$p.PSObject.Properties['harnessOf']
    $stamped = [bool]($p.PSObject.Properties['stampedTag'] -and $p.stampedTag)
    [pscustomobject]@{ Name = $p.name; Tag = $tag; Version = "$version"; From = $last; Paths = @($p.paths); Harness = $harness
        Stamped = $stamped }
}

foreach ($r in @($plan)) {
    $notes = Get-Notes $r.From $r.Paths
    Write-Host "$($r.Name) $($r.Version): $($r.Tag) on $Sha (since $(if ($r.From) { $r.From } else { 'the start' }))`n$notes"
    if ($DryRun) { if ($r.Stamped) { Write-Host "(tagged on a commit of the stamped files)" }; continue }
    $target = $Sha
    if ($r.Stamped) {
        # A registry that builds from the tag's source (R-universe, Julia's General registry) reads the version there,
        # so the tag is on a commit of the merge with the version written in (stamp.ps1). It is on no branch: main keeps
        # the placeholder.
        & (Join-Path $PSScriptRoot 'stamp.ps1') -Tag $r.Tag -Config $Config
        git -c user.name='endjin-bot[bot]' -c user.email='endjin-bot[bot]@users.noreply.github.com' commit -q -a -m "$($r.Name) $($r.Version)"
        if ($LASTEXITCODE) { throw "the stamped commit for $($r.Tag) could not be made" }
        $target = git rev-parse HEAD
        $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:GH_TOKEN"))
        git -c "http.extraheader=AUTHORIZATION: basic $auth" push -q origin "${target}:refs/tags/$($r.Tag)"
        if ($LASTEXITCODE) { throw "the tag $($r.Tag) could not be pushed" }
        git checkout -q --detach $Sha
    }
    # A harness release is never the repository's latest: that stays the library's.
    $body = @{ tag_name = $r.Tag; target_commitish = $target; name = "$($r.Name) $($r.Version)"; body = $notes
        make_latest = if ($r.Harness) { 'false' } else { 'true' } } | ConvertTo-Json
    $body | gh api "repos/$env:GITHUB_REPOSITORY/releases" --method POST --input - --jq .html_url
    if ($LASTEXITCODE) { throw "the release $($r.Tag) could not be made" }
}
if (-not @($plan)) { Write-Host 'Nothing changed that a package releases.' }
