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

$IgnoreDirs = @(
    'AppData\Roaming\Zoom\data\WaitingRoom',
    'AppData\Roaming\ManyCam\Backgrounds',
    'AppData\Local\Google\Chrome\User Data\Default\Extensions'
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
$RestrictedProfiles = [System.Collections.Generic.List[string]]::new()

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
            $Found = @($Found) | Where-Object {
                $Path = $_
                -not ($IgnoreDirs | Where-Object { $Path -like "*\$_\*" -or $Path -like "*\$_" })
            }
            if ($Found) {
                $SubDirCounts[$Sub] = @($Found).Count
                foreach ($F in $Found) { $Videos.Add($F) }
            }
        }
    }

    # Check if current user has full access to this profile directory
    $HasFullAccess = $false
    try {
        $Acl = Get-Acl -Path $Profile.FullName -ErrorAction Stop
        $CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $UserSids = @($CurrentIdentity.User.Value) + @($CurrentIdentity.Groups | ForEach-Object { $_.Value })
        foreach ($Rule in $Acl.Access) {
            if ($Rule.AccessControlType -eq 'Allow' -and
                $Rule.FileSystemRights.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) {
                try {
                    $RuleSid = $Rule.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                    if ($UserSids -contains $RuleSid) {
                        $HasFullAccess = $true
                        break
                    }
                } catch { }
            }
        }
    } catch {
        # Cannot read ACL — no access
    }
    if (-not $HasFullAccess) {
        $RestrictedProfiles.Add($Profile.FullName)
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

# ---------------------------------------------------------------------------
# Offer to grant full access to restricted profile directories
# ---------------------------------------------------------------------------
if ($RestrictedProfiles.Count -gt 0) {
    Write-Host ''
    Write-Host 'The following profile directories are not fully accessible to the current user:'
    foreach ($P in $RestrictedProfiles) {
        Write-Host "  $P"
    }
    Write-Host ''

    # Determine admin membership and elevation status
    $Principal = New-Object System.Security.Principal.WindowsPrincipal(
        [System.Security.Principal.WindowsIdentity]::GetCurrent())
    $IsElevated = $Principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)

    # Check admin group membership via whoami (visible even in non-elevated sessions)
    $AdminSid  = 'S-1-5-32-544'
    $IsAdmin   = $false
    try {
        $GroupsCsv = whoami /groups /fo csv 2>$null | ConvertFrom-Csv
        $IsAdmin   = ($GroupsCsv | Where-Object { $_.SID -eq $AdminSid }) -ne $null
    } catch { }

    if (-not $IsAdmin) {
        Write-Host 'Cannot grant access: the current user is not a member of the Administrators group.'
    } elseif (-not $IsElevated) {
        Write-Host 'Cannot grant access: this process is not running with elevated (Administrator) privileges.'
        Write-Host 'Re-run this script from an elevated PowerShell prompt to grant access.'
    } else {
        foreach ($P in $RestrictedProfiles) {
            $Answer = Read-Host "Grant full access to '$P'? (y/n)"
            if ($Answer -eq 'y') {
                Write-Host "  Granting full access to $P ..."
                & icacls $P /grant "${env:USERNAME}:(OI)(CI)F" /T /Q
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Access granted."
                } else {
                    Write-Host "  Failed to grant access (icacls exit code $LASTEXITCODE)."
                }
            } else {
                Write-Host "  Skipped."
            }
        }
    }
}
