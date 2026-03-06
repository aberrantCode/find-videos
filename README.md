# find-videos

A PowerShell utility that scans Windows user profiles for MP4 video files, generates per-user VLC playlists, and exports a consolidated CSV report.

## Features

- Searches six common subdirectories within each profile under `C:\Users`
- Generates a VLC-compatible XSPF playlist for every user that has videos
- Exports a single CSV (`all-videos.csv`) with profile name and full file path for every discovered video
- Prints a summary to the console grouped by profile and subdirectory

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- [VLC media player](https://www.videolan.org/) (to open `.xspf` playlists)
- Sufficient read permissions on `C:\Users` and its subdirectories

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

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Commit your changes: `git commit -m "feat: description"`
4. Push to the branch: `git push origin feat/your-feature`
5. Open a pull request targeting `dev`

## License

MIT
