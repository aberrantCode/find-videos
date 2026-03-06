#Requires -Version 5.1
<#
.SYNOPSIS
    Entry point — invokes Find-Videos.ps1 from the src directory.
.DESCRIPTION
    Resolves the repository root relative to this script's location and
    delegates execution to src\Find-Videos.ps1, forwarding all parameters.
.PARAMETER UsersRoot
    Root directory containing user profiles. Defaults to C:\Users.
.PARAMETER DataDir
    Output directory for playlists and CSV. Defaults to <repo-root>\data.
#>

[CmdletBinding()]
param(
    [string]$UsersRoot = 'C:\Users',
    [string]$DataDir
)

$RepoRoot  = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $RepoRoot 'src\Find-Videos.ps1'

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Cannot locate Find-Videos.ps1 at: $ScriptPath"
    exit 1
}

$Params = @{ UsersRoot = $UsersRoot }

if ($DataDir) {
    $Params['DataDir'] = $DataDir
} else {
    $Params['DataDir'] = Join-Path $RepoRoot 'data'
}

& $ScriptPath @Params @args
