<#
.SYNOPSIS
    Compiles and runs each program of the getting-started page the documentation site publishes
    (docs/getting-started.md), so that the page shows only code that works.

.DESCRIPTION
    Each block of Pascal on the page is a whole program. It is compiled against src with the same compiler and options
    as tools/build.ps1 gives the tests, and run; a program that does not compile, or ends with an exception, fails the
    script.

.PARAMETER Fpc
    The Free Pascal compiler. The default is the fpc on the PATH.

.PARAMETER Options
    Further options for the compiler, such as '-O3 -Px86_64'.

.EXAMPLE
    pwsh tools/docs/run-getting-started.ps1 -Fpc ~/sdk/fpc-3.2.2/bin/fpc -Options '-O1'
#>
param(
    [string] $Fpc = 'fpc',
    [string] $Options = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$page = [System.IO.File]::ReadAllText((Join-Path $root 'docs' 'getting-started.md'))
$blocks = @([regex]::Matches($page, '(?ms)^```pascal\n(.*?)^```$') | ForEach-Object { $_.Groups[1].Value })
if ($blocks.Count -lt 5) { throw "The page has $($blocks.Count) programs." }

$work = Join-Path ([System.IO.Path]::GetTempPath()) "getting-started-$PID"
New-Item -ItemType Directory -Force -Path (Join-Path $work 'lib'), (Join-Path $work 'bin') | Out-Null
$failed = @()
try {
    for ($n = 0; $n -lt $blocks.Count; $n++) {
        $name = if ($blocks[$n] -match '(?m)^program (\w+);') { $Matches[1] } else { "Example$n" }
        $source = Join-Path $work "$name.pas"
        [System.IO.File]::WriteAllText($source, $blocks[$n])
        $arguments = @($Options -split ' ' | Where-Object { $_ }) +
            @('-vew', "-FU$(Join-Path $work 'lib')", "-Fu$(Join-Path $root 'src')", "-Fi$(Join-Path $root 'src')",
              "-FE$(Join-Path $work 'bin')", $source)
        & $Fpc @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) { $failed += "$name (compile)"; continue }
        $exe = Join-Path $work 'bin' $name
        if ($IsWindows) { $exe += '.exe' }
        & $exe
        if ($LASTEXITCODE -ne 0) { $failed += "$name (run)"; continue }
        Write-Host "${name}: ok"
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($failed.Count -gt 0) { throw "The getting-started programs that failed: $($failed -join ', ')" }
Write-Host "$($blocks.Count) getting-started programs compiled and ran."
