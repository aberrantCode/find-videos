#Requires -Version 7.0
<#
.SYNOPSIS
    Local pre-PR validation gate for find-videos.
.DESCRIPTION
    The repo has no test suite, so this gate performs a lightweight but real
    check: it parses every .ps1 file with the PowerShell language parser and
    fails the push on any syntax (parse) error. Invoked by
    scripts/git-hooks/pre-push on every push that carries commits. If there are
    no .ps1 files the gate reports and exits 0 (present-and-wired).
.PARAMETER Json
    Reserved for parity with the shared gate surface; unused here.
.NOTES
    Exit codes: 0 = parsed clean (or no files), 1 = syntax error, 2 = execution
    error.
#>
[CmdletBinding()]
param([switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

$ps1Files = @(Get-ChildItem -Path $repoRoot -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
if ($ps1Files.Count -eq 0) {
    Write-Host 'validate: no .ps1 files found -- nothing to check (present-and-wired).'
    exit 0
}

$errorCount = 0
foreach ($file in $ps1Files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $errorCount += $parseErrors.Count
        Write-Host "validate: parse error(s) in $($file.Name):"
        foreach ($e in $parseErrors) { Write-Host "  $($e.Message)" }
    }
}

if ($errorCount -gt 0) {
    Write-Host "validate: PowerShell parse FAILED ($errorCount error(s))."
    exit 1
}
Write-Host "validate: PowerShell parse passed ($($ps1Files.Count) file(s))."
exit 0
