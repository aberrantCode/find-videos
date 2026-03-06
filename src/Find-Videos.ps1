#Requires -Version 5.1
<#
.SYNOPSIS
    Searches user profiles for MP4 files, generates VLC playlists, and exports a CSV.
.DESCRIPTION
    Scans specified subdirectories of each profile under C:\Users for .mp4 files.
    Outputs a VLC XSPF playlist per user to .\data\ and a combined CSV.
#>

[CmdletBinding()]
param(
    [string]$UsersRoot = 'C:\Users',
    [string]$DataDir   = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data')
)

$SubDirs = @(
    'Videos',
    'Downloads',
    'AppData\Local',
    'AppData\Roaming',
    'Documents',
    'Desktop'
)

# ---------------------------------------------------------------------------
# Setup output directory
# ---------------------------------------------------------------------------
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir | Out-Null
}

$CsvPath = Join-Path $DataDir 'all-videos.csv'
$CsvRows = [System.Collections.Generic.List[PSCustomObject]]::new()

# ---------------------------------------------------------------------------
# Iterate profiles
# ---------------------------------------------------------------------------
$Profiles = Get-ChildItem -Path $UsersRoot -Directory -ErrorAction SilentlyContinue

foreach ($Profile in $Profiles) {
    $ProfileName = $Profile.Name
    $Videos      = [System.Collections.Generic.List[string]]::new()

    # Track per-subdir counts for console output
    $SubDirCounts = [ordered]@{}

    foreach ($Sub in $SubDirs) {
        $SearchPath = Join-Path $Profile.FullName $Sub

        if (-not (Test-Path $SearchPath)) { continue }

        $Found = Get-ChildItem -Path $SearchPath -Filter '*.mp4' -Recurse `
                               -ErrorAction SilentlyContinue -Force |
                 Select-Object -ExpandProperty FullName

        if ($Found) {
            $SubDirCounts[$Sub] = @($Found).Count
            foreach ($F in $Found) { $Videos.Add($F) }
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
