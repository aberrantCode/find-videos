#Requires -Version 5.1
<#
.SYNOPSIS
    Searches user profiles for MP4 files, generates VLC playlists, and exports a CSV.
.DESCRIPTION
    Scans specified subdirectories of each profile under C:\Users for .mp4 files.
    Outputs a VLC XSPF playlist per user to .\data\ and a combined CSV.

    By default, known application assets (bundled demo clips, browser-extension
    stubs, cached UI videos) are excluded so the results contain only real user
    recordings. Use -IncludeAppAssets to keep everything, or -ExcludePatterns to
    supply your own regex list.
.PARAMETER UsersRoot
    Root directory containing user profiles. Defaults to C:\Users.
.PARAMETER DataDir
    Output directory for playlists and CSV.
.PARAMETER ExcludePaths
    Literal path fragments matched (case-insensitively) against each full file
    path. A file containing any fragment is excluded. Defaults to known
    app-asset locations.
.PARAMETER IncludeAppAssets
    Disable filtering entirely and report every MP4 found.
#>

[CmdletBinding()]
param(
    [string]$UsersRoot = 'C:\Users',
    [string]$DataDir   = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data'),

    # Known application-asset locations — none of these hold user recordings.
    [string[]]$ExcludePaths = @(
        '\AppData\Roaming\ManyCam\Backgrounds\',            # ManyCam bundled demo backgrounds
        '\web-accessible-resources\',                       # browser-extension resources (noopmp4 stubs)
        '\AppData\Roaming\Zoom\data\WaitingRoom\',          # Zoom waiting-room clips
        '\AppData\Local\Microsoft\Office\SolutionPackages\' # Office offline package resources
    ),

    [switch]$IncludeAppAssets
)

$SubDirs = @(
    'Videos',
    'Downloads',
    'AppData\Local',
    'AppData\Roaming',
    'Documents',
    'Desktop'
)

$ActiveExclusions = if ($IncludeAppAssets) { @() } else { $ExcludePaths }

# ---------------------------------------------------------------------------
# Setup output directory
# ---------------------------------------------------------------------------
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir | Out-Null
}

$CsvPath       = Join-Path $DataDir 'all-videos.csv'
$CsvRows       = [System.Collections.Generic.List[PSCustomObject]]::new()
$ExcludedTotal = 0

# ---------------------------------------------------------------------------
# Iterate profiles
# ---------------------------------------------------------------------------
$Profiles = Get-ChildItem -Path $UsersRoot -Directory -ErrorAction SilentlyContinue

foreach ($UserProfile in $Profiles) {
    $ProfileName = $UserProfile.Name
    $Videos      = [System.Collections.Generic.List[string]]::new()

    # Track per-subdir counts for console output
    $SubDirCounts = [ordered]@{}

    foreach ($Sub in $SubDirs) {
        $SearchPath = Join-Path $UserProfile.FullName $Sub

        if (-not (Test-Path $SearchPath)) { continue }

        $Found = Get-ChildItem -Path $SearchPath -Filter '*.mp4' -Recurse `
                               -ErrorAction SilentlyContinue -Force |
                 Select-Object -ExpandProperty FullName

        if (-not $Found) { continue }

        # Drop known application assets
        $Kept = foreach ($F in $Found) {
            $IsAsset = $false
            foreach ($Fragment in $ActiveExclusions) {
                if ($F.IndexOf($Fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $IsAsset = $true
                    break
                }
            }
            if ($IsAsset) { $ExcludedTotal++ } else { $F }
        }

        if ($Kept) {
            $SubDirCounts[$Sub] = @($Kept).Count
            foreach ($K in $Kept) { $Videos.Add($K) }
        }
    }

    if ($Videos.Count -eq 0) { continue }

    # Console output
    Write-Host $ProfileName
    foreach ($Key in $SubDirCounts.Keys) {
        Write-Host "  \$Key  ($($SubDirCounts[$Key]) video$(if ($SubDirCounts[$Key] -ne 1) { 's' }))"
    }
    Write-Host ''

    # CSV rows
    foreach ($V in $Videos) {
        $CsvRows.Add([PSCustomObject]@{
            Profile   = $ProfileName
            FullPath  = $V
        })
    }

    # VLC XSPF playlist
    $PlaylistPath = Join-Path $DataDir "$ProfileName.xspf"

    $Tracks = foreach ($V in $Videos) {
        $Encoded = [Uri]::EscapeUriString($V.Replace('\', '/'))
        "        <track>`n            <location>file:///$Encoded</location>`n        </track>"
    }

    $Xspf = @"
<?xml version="1.0" encoding="UTF-8"?>
<playlist xmlns="http://xspf.org/ns/0/" xmlns:vlc="http://www.videolan.org/vlc/playlist/ns/0/" version="1">
    <title>$ProfileName</title>
    <trackList>
$($Tracks -join "`n")
    </trackList>
</playlist>
"@

    [System.IO.File]::WriteAllText($PlaylistPath, $Xspf, [System.Text.Encoding]::UTF8)
    Write-Verbose "Playlist written: $PlaylistPath"
}

# ---------------------------------------------------------------------------
# Write CSV
# ---------------------------------------------------------------------------
if ($CsvRows.Count -gt 0) {
    $CsvRows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV written: $CsvPath ($($CsvRows.Count) total videos)"
} else {
    Write-Host 'No MP4 files found across any profile.'
}

if ($ExcludedTotal -gt 0) {
    Write-Host "Excluded $ExcludedTotal application asset file$(if ($ExcludedTotal -ne 1) { 's' }) (use -IncludeAppAssets to keep them)."
}
