#Requires -Version 5.1
<#
.SYNOPSIS
    Searches user profiles for MP4 files, generates VLC playlists, and exports a CSV.
.DESCRIPTION
    Scans specified subdirectories of each profile under C:\Users for .mp4 files.
    Outputs a VLC XSPF playlist per user to .\data\ and a combined CSV.

    By default, known application assets (bundled demo clips, browser-extension
    stubs, cached UI videos) are excluded so the results contain only real user
    recordings. Use -IncludeAppAssets to keep everything, or -ExcludePaths to
    supply your own list of path fragments.
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
    # Union of the exclusions from both branches; the three dev entries are kept
    # verbatim, and \web-accessible-resources\ additionally catches extension
    # stubs under non-Default Chrome profiles (e.g. "Profile 1").
    [string[]]$ExcludePaths = @(
        '\AppData\Roaming\ManyCam\Backgrounds\',                       # ManyCam bundled demo backgrounds
        '\AppData\Roaming\Zoom\data\WaitingRoom\',                     # Zoom waiting-room clips
        '\AppData\Local\Google\Chrome\User Data\Default\Extensions\',  # Chrome extension media
        '\web-accessible-resources\',                                  # extension resources (noopmp4 stubs)
        '\AppData\Local\Microsoft\Office\SolutionPackages\'             # Office offline package resources
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
$RestrictedProfiles = [System.Collections.Generic.List[string]]::new()

# Pre-compute current user SID for ACL checks (once, not per-profile).
# Only check the user's personal SID — not group memberships like
# BUILTIN\Administrators — so we detect profiles where the user lacks
# an explicit personal FullControl ACE (important for non-elevated access).
$CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($CurrentIdentity)
$IsElevated = $CurrentPrincipal.IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
$AdminSid = 'S-1-5-32-544'
$CurrentUserSid = $CurrentIdentity.User.Value

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

    # Check if current user has full access to this profile directory
    $HasFullAccess = $false
    try {
        $Acl = Get-Acl -Path $UserProfile.FullName -ErrorAction Stop
        foreach ($Rule in $Acl.Access) {
            if ($Rule.AccessControlType -eq 'Allow' -and
                $Rule.FileSystemRights.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) {
                try {
                    $RuleSid = $Rule.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                    if ($RuleSid -eq $CurrentUserSid) {
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
        $RestrictedProfiles.Add($UserProfile.FullName)
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

    # Check admin group membership via whoami (visible even in non-elevated sessions)
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
        $Total = $RestrictedProfiles.Count
        $Answer = Read-Host "Grant full access to all $Total profile directories? (y/n)"

        if ($Answer -ne 'y') {
            Write-Host 'Skipped - no permissions were changed.'
        } else {
            # Profiles icacls could not touch at all, and profiles it granted
            # except for a few protected items (Norton and friends).
            $GrantFailures = [System.Collections.Generic.List[PSCustomObject]]::new()
            $PartialGrants = [System.Collections.Generic.List[PSCustomObject]]::new()
            $Index = 0

            foreach ($P in $RestrictedProfiles) {
                $Index++
                Write-Progress -Activity 'Granting full access' `
                    -Status "$Index of $Total : $P" `
                    -PercentComplete ([int](100 * $Index / $Total))

                # /C  : keep going when an individual file/dir is denied
                #       (e.g. Norton and other tamper-protected directories)
                # /Q  : suppress per-file success messages
                # *SID: grant by SID so local/domain name resolution can't fail
                $IcaclsOut  = & icacls $P /grant "*${CurrentUserSid}:(OI)(CI)F" /T /C /Q 2>&1
                $IcaclsExit = $LASTEXITCODE

                $OutText = ($IcaclsOut | ForEach-Object { $_.ToString() }) -join "`n"

                # icacls reports its own tally; trust it over the exit code, which
                # is non-zero even when only one item out of hundreds was denied.
                $Succeeded  = -1
                $Failed     = -1
                $OkMatch    = [regex]::Match($OutText, 'Successfully processed (\d+) file')
                $FailMatch  = [regex]::Match($OutText, 'Failed processing (\d+) file')
                if ($OkMatch.Success)   { $Succeeded = [int]$OkMatch.Groups[1].Value }
                if ($FailMatch.Success) { $Failed    = [int]$FailMatch.Groups[1].Value }

                $FailedItems = @(
                    $IcaclsOut |
                        Where-Object { $_ -match ': Access is denied\.$|: The system cannot find' } |
                        ForEach-Object { $_.ToString() }
                )

                if ($Succeeded -lt 0) {
                    # No summary line at all - icacls never got started on this tree.
                    if ($IcaclsExit -ne 0) {
                        $GrantFailures.Add([PSCustomObject]@{
                            Path   = $P
                            Reason = "icacls exit code $IcaclsExit"
                            Detail = $OutText
                        })
                    }
                } elseif ($Succeeded -eq 0 -and ($Failed -gt 0 -or $FailedItems.Count -gt 0)) {
                    # Nothing in the tree was updated.
                    $GrantFailures.Add([PSCustomObject]@{
                        Path   = $P
                        Reason = "no items updated (icacls exit code $IcaclsExit)"
                        Detail = $OutText
                    })
                } elseif ($Failed -gt 0 -or $FailedItems.Count -gt 0) {
                    $PartialGrants.Add([PSCustomObject]@{
                        Path  = $P
                        Count = [Math]::Max($Failed, $FailedItems.Count)
                        Items = $FailedItems
                    })
                }
            }

            Write-Progress -Activity 'Granting full access' -Completed

            $FullyGranted = $Total - $GrantFailures.Count - $PartialGrants.Count
            Write-Host ''
            Write-Host "Granted full access to $FullyGranted of $Total profile directories."

            if ($PartialGrants.Count -gt 0) {
                Write-Host ''
                Write-Host "$($PartialGrants.Count) profile(s) granted except for protected items:"
                foreach ($G in $PartialGrants) {
                    Write-Host "  $($G.Path) - $($G.Count) item(s) skipped"
                    foreach ($I in $G.Items) { Write-Host "      $I" }
                }
            }

            if ($GrantFailures.Count -gt 0) {
                Write-Host ''
                Write-Host "$($GrantFailures.Count) profile(s) FAILED to fix:"
                foreach ($F in $GrantFailures) {
                    Write-Host "  $($F.Path) - $($F.Reason)"
                    foreach ($L in ($F.Detail -split "`n")) {
                        if ($L.Trim()) { Write-Host "      $($L.Trim())" }
                    }
                }
            }
        }
    }
}
