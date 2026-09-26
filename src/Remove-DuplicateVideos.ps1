#Requires -Version 5.1
<#
.SYNOPSIS
    Hashes the discovered videos, identifies duplicates, optionally recycles them,
    and writes a consolidation plan for moving survivors into a single folder.
.DESCRIPTION
    Reads all-videos.csv (produced by Find-Videos.ps1), groups files by SHA256
    content hash, and selects one keeper per duplicate group. Files are only
    hashed when their byte length is shared by at least one other file, so unique
    sizes are never read.

    Runs as a DRY RUN unless -Delete is supplied. With -Delete, duplicates are
    sent to the Recycle Bin (recoverable) unless -Permanent is also supplied.

    Keeper policy: oldest CreationTime wins (the original copy); ties break on
    shortest full path, then alphabetically, so the choice is deterministic.
.PARAMETER DataDir
    Directory holding all-videos.csv; reports are written here.
.PARAMETER Delete
    Actually remove the duplicates. Without this, nothing is modified.
.PARAMETER Permanent
    With -Delete, bypass the Recycle Bin and delete irreversibly.
.PARAMETER TargetFolder
    Destination recorded in the consolidation plan for a later move. Nothing is
    moved by this script.
.OUTPUTS
    video-hashes.csv      every file with size, hash, timestamps
    duplicate-groups.csv  one row per duplicate copy, marked Keep or Duplicate
    move-plan.csv         surviving files with collision-free target filenames
#>

[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data'),
    [switch]$Delete,
    [switch]$Permanent,
    [string]$TargetFolder = 'C:\Videos\Consolidated'
)

$ErrorActionPreference = 'Stop'

$CsvPath = Join-Path $DataDir 'all-videos.csv'
if (-not (Test-Path $CsvPath)) {
    Write-Error "Cannot find $CsvPath — run Start-App.ps1 first."
    exit 1
}

# ---------------------------------------------------------------------------
# Load inventory and stat each file
# ---------------------------------------------------------------------------
$Rows  = Import-Csv -Path $CsvPath
$Files = [System.Collections.Generic.List[PSCustomObject]]::new()
$Missing = 0

foreach ($Row in $Rows) {
    $Item = Get-Item -LiteralPath $Row.FullPath -Force -ErrorAction SilentlyContinue
    if (-not $Item) { $Missing++; continue }

    $Files.Add([PSCustomObject]@{
        Profile  = $Row.Profile
        FullPath = $Item.FullName
        Name     = $Item.Name
        Length   = $Item.Length
        Created  = $Item.CreationTime
        Modified = $Item.LastWriteTime
        Hash     = $null
    })
}

Write-Host "Inventory: $($Files.Count) files$(if ($Missing) { " ($Missing listed path(s) no longer exist)" })"

# ---------------------------------------------------------------------------
# Hash only files whose size is shared — identical content implies identical size
# ---------------------------------------------------------------------------
$SizeGroups   = $Files | Group-Object Length
$NeedHash     = $SizeGroups | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group }
$UniqueBySize = ($Files.Count - @($NeedHash).Count)

Write-Host "Unique by size (not hashed): $UniqueBySize"
Write-Host "Hashing $(@($NeedHash).Count) file(s) with shared sizes..."

$Done = 0
foreach ($F in $NeedHash) {
    $Done++
    Write-Progress -Activity 'Hashing videos' -Status $F.Name `
                   -PercentComplete (100 * $Done / [Math]::Max(1, @($NeedHash).Count))
    try {
        $F.Hash = (Get-FileHash -LiteralPath $F.FullPath -Algorithm SHA256).Hash
    } catch {
        Write-Warning "Could not hash $($F.FullPath): $($_.Exception.Message)"
    }
}
Write-Progress -Activity 'Hashing videos' -Completed

$Files | Select-Object Profile, Name, Length, Hash, Created, Modified, FullPath |
    Export-Csv -Path (Join-Path $DataDir 'video-hashes.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Group by hash, elect a keeper per group
# ---------------------------------------------------------------------------
$DupGroups = $Files | Where-Object { $_.Hash } | Group-Object Hash |
             Where-Object { $_.Count -gt 1 }

$GroupRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$ToDelete   = [System.Collections.Generic.List[PSCustomObject]]::new()
$Keepers    = [System.Collections.Generic.List[PSCustomObject]]::new()
$GroupIndex = 0

foreach ($G in $DupGroups) {
    $GroupIndex++
    $Ordered = $G.Group | Sort-Object Created, { $_.FullPath.Length }, FullPath
    $Keeper  = $Ordered[0]

    foreach ($F in $Ordered) {
        $IsKeeper = [Object]::ReferenceEquals($F, $Keeper)
        $GroupRows.Add([PSCustomObject]@{
            Group    = $GroupIndex
            Action   = if ($IsKeeper) { 'Keep' } else { 'Duplicate' }
            Profile  = $F.Profile
            Name     = $F.Name
            Length   = $F.Length
            Created  = $F.Created
            Hash     = $F.Hash
            FullPath = $F.FullPath
        })
        if (-not $IsKeeper) { $ToDelete.Add($F) }
    }
    $Keepers.Add($Keeper)
}

$GroupRows | Export-Csv -Path (Join-Path $DataDir 'duplicate-groups.csv') `
                        -NoTypeInformation -Encoding UTF8

$ReclaimBytes = ($ToDelete | Measure-Object -Property Length -Sum).Sum
if (-not $ReclaimBytes) { $ReclaimBytes = 0 }

Write-Host ''
Write-Host "Duplicate groups: $($DupGroups.Count)"
Write-Host "Redundant copies: $($ToDelete.Count)  ($([Math]::Round($ReclaimBytes / 1MB, 1)) MB reclaimable)"

# ---------------------------------------------------------------------------
# Delete (or report what would be deleted)
# ---------------------------------------------------------------------------
$Removed = 0

if ($Delete -and $ToDelete.Count -gt 0) {
    if (-not $Permanent) {
        Add-Type -AssemblyName Microsoft.VisualBasic
    }

    foreach ($F in $ToDelete) {
        try {
            if ($Permanent) {
                Remove-Item -LiteralPath $F.FullPath -Force
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $F.FullPath,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            }
            $Removed++
            Write-Verbose "Removed: $($F.FullPath)"
        } catch {
            Write-Warning "Failed to remove $($F.FullPath): $($_.Exception.Message)"
        }
    }

    $Where = if ($Permanent) { 'permanently deleted' } else { 'moved to the Recycle Bin' }
    Write-Host "Removed $Removed of $($ToDelete.Count) duplicate(s) — $Where."
} elseif ($ToDelete.Count -gt 0) {
    Write-Host 'DRY RUN — nothing removed. Re-run with -Delete to recycle these copies.'
}

# ---------------------------------------------------------------------------
# Consolidation plan: survivors with collision-free target names
# ---------------------------------------------------------------------------
$DeletedPaths = @{}
if ($Delete) { foreach ($F in $ToDelete) { $DeletedPaths[$F.FullPath] = $true } }

$Survivors = $Files | Where-Object { -not $DeletedPaths.ContainsKey($_.FullPath) } |
             Sort-Object Profile, Name

$UsedNames = @{}
$PlanRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($F in $Survivors) {
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($F.Name)
    $Ext  = [System.IO.Path]::GetExtension($F.Name)

    # Prefix with the profile so same-named recordings stay distinguishable
    $Candidate = "$($F.Profile) - $Base$Ext"
    $Counter   = 1
    while ($UsedNames.ContainsKey($Candidate.ToLowerInvariant())) {
        $Counter++
        $Candidate = "$($F.Profile) - $Base ($Counter)$Ext"
    }
    $UsedNames[$Candidate.ToLowerInvariant()] = $true

    $PlanRows.Add([PSCustomObject]@{
        Profile    = $F.Profile
        SourcePath = $F.FullPath
        TargetName = $Candidate
        TargetPath = Join-Path $TargetFolder $Candidate
        Length     = $F.Length
        Created    = $F.Created
        Hash       = $F.Hash
    })
}

$PlanPath = Join-Path $DataDir 'move-plan.csv'
$PlanRows | Export-Csv -Path $PlanPath -NoTypeInformation -Encoding UTF8

$PlanBytes = ($PlanRows | Measure-Object -Property Length -Sum).Sum
if (-not $PlanBytes) { $PlanBytes = 0 }

Write-Host ''
Write-Host "Move plan: $($PlanRows.Count) file(s), $([Math]::Round($PlanBytes / 1MB, 1)) MB -> $TargetFolder"
Write-Host "Plan written: $PlanPath"
