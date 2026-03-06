# find-videos

A PowerShell utility that scans Windows user profiles for MP4 video files, generates per-user VLC playlists, and exports a consolidated CSV report.

## Features

- Searches six common subdirectories within each profile under `C:\Users`
- Excludes known non-user-content directories (Zoom waiting room assets, ManyCam backgrounds, Chrome extensions)
- Generates a VLC-compatible XSPF playlist for every user that has videos
- Exports a single CSV (`all-videos.csv`) with profile name and full file path for every discovered video
- Prints a summary to the console grouped by profile and subdirectory
- Detects profile directories the current user cannot fully access and offers to grant permissions (requires Administrator elevation)

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- [VLC media player](https://www.videolan.org/) (to open `.xspf` playlists)
- Sufficient read permissions on `C:\Users` and its subdirectories (the script can help fix this — see [Profile Access](#profile-access) below)

## Project Structure

```
find-videos/
├── scripts/
│   └── Start-App.ps1       # Entry point — run this
├── src/
│   └── Find-Videos.ps1     # Core search and output logic
├── data/                   # Generated output (git-ignored)
│   ├── <Profile>.xspf      # Per-user VLC playlist
│   └── all-videos.csv      # Combined CSV report
├── .gitignore
└── README.md
```

## Usage

Run from any PowerShell prompt at the repository root:

```powershell
.\scripts\Start-App.ps1
```

### Parameters

| Parameter    | Default      | Description                                      |
|-------------|--------------|--------------------------------------------------|
| `-UsersRoot` | `C:\Users`   | Root directory containing user profile folders   |
| `-DataDir`   | `.\data`     | Output directory for playlists and the CSV file  |

### Examples

```powershell
# Default — scan C:\Users, output to .\data
.\scripts\Start-App.ps1

# Custom users root
.\scripts\Start-App.ps1 -UsersRoot D:\Users

# Custom output directory
.\scripts\Start-App.ps1 -DataDir C:\Reports\VideoScan

# Verbose output (prints each playlist path as it is written)
.\scripts\Start-App.ps1 -Verbose
```

## Output

### Console

```
john.doe
  \Videos          (12 videos)
  \Downloads       (3 videos)
  \Documents       (1 video)

jane.smith
  \Desktop         (2 videos)

CSV written: C:\development\find-videos\data\all-videos.csv (18 total videos)

The following profile directories are not fully accessible to the current user:
  C:\Users\old.admin

Cannot grant access: this process is not running with elevated (Administrator) privileges.
Re-run this script from an elevated PowerShell prompt to grant access.
```

### `all-videos.csv`

```csv
"Profile","FullPath"
"john.doe","C:\Users\john.doe\Videos\example.mp4"
"jane.smith","C:\Users\jane.smith\Desktop\clip.mp4"
```

### XSPF Playlists

Each `data\<ProfileName>.xspf` file can be opened directly in VLC via **Media → Open File** or by double-clicking if `.xspf` is associated with VLC.

## Searched Directories

The following subdirectories are scanned recursively within each profile:

- `\Videos`
- `\Downloads`
- `\AppData\Local`
- `\AppData\Roaming`
- `\Documents`
- `\Desktop`

Directories that do not exist or contain no MP4 files are silently skipped.

### Excluded Directories

The following subdirectories are excluded from results because they contain application-managed video files rather than user content:

- `\AppData\Roaming\Zoom\data\WaitingRoom`
- `\AppData\Roaming\ManyCam\Backgrounds`
- `\AppData\Local\Google\Chrome\User Data\Default\Extensions`

## Profile Access

After scanning, the script checks the ACL on each profile directory to determine whether the current user has `FullControl`. If any profiles are restricted, the script lists them and offers to grant access.

Two conditions must be met before access can be granted:

1. **Administrator membership** — the current user must be a member of the local `Administrators` group.
2. **Elevated process** — the PowerShell session must be running as Administrator (right-click → *Run as administrator*).

If either condition is not met, the script displays which requirement is missing. When both are satisfied, the script prompts for each restricted profile:

```
Grant full access to 'C:\Users\old.admin'? (y/n): y
  Granting full access to C:\Users\old.admin ...
  Access granted.
```

Access is granted via `icacls` with inherited (`OI`/`CI`) full-control permissions applied recursively.

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Commit your changes: `git commit -m "feat: description"`
4. Push to the branch: `git push origin feat/your-feature`
5. Open a pull request targeting `dev`

## License

MIT
