<#
.SYNOPSIS
Builds the tests and the tools of the library with Free Pascal.

.DESCRIPTION
Each program is built into bin/, with the compiled units in lib/. The compiler's warnings and notes about the
library's units are printed, and a program that does not build fails the script.

.PARAMETER Fpc
The Free Pascal compiler. The default is the fpc on the PATH.

.PARAMETER Options
The options for the compiler, as one string. The default is -O3.

.PARAMETER Programs
The programs to build. The default is all of them.

.EXAMPLE
pwsh tools/build.ps1
pwsh tools/build.ps1 -Fpc ~/sdk/fpc-3.2.2/bin/fpc -Options '-O1 -gl'
#>
[CmdletBinding()]
param(
    [string] $Fpc = 'fpc',
    [string] $Options = '-O3',
    [string[]] $Programs = @('tests/TestEngine.pas', 'tests/TestSearch.pas', 'tools/dataset/run.pas')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    New-Item -ItemType Directory -Force -Path lib, bin | Out-Null
    $failed = @()
    foreach ($program in $Programs) {
        $arguments = @($Options -split '\s+' | Where-Object { $_ -ne '' }) +
            @('-vewn', '-FUlib', '-Fusrc', '-Fisrc', '-FEbin', $program)
        Write-Host "fpc $($arguments -join ' ')"
        & $Fpc @arguments
        if ($LASTEXITCODE -ne 0) { $failed += $program }
    }
    if ($failed.Count -gt 0) { throw "Did not build: $($failed -join ', ')" }
}
finally {
    Pop-Location
}
