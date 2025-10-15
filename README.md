# File Organization Script by Year

A robust bash script that automatically organizes photos, videos, and other files into year-based folders based on when they were created or taken.

## Features

- **Smart Date Detection**: Extracts dates from multiple sources
  - EXIF data for photos (most accurate for images)
  - Video metadata for video files
  - File modification timestamps as fallback

- **Handles Complex Scenarios**:
  - Deeply nested folder structures
  - Duplicate filenames (automatically renames with counters)
  - Large file collections

- **Safe Operations**:
  - Dry-run mode to preview changes
  - Detailed logging
  - Confirmation prompt before moving files

- **Flexible Configuration**:
  - Customizable source and destination directories
  - Optional verbose output
  - Log file support

## Requirements

### Required
- Bash 4.0 or higher
- Basic Unix tools (find, stat, mv)

### Optional (for best results)
- `exiftool` - for extracting EXIF data from photos
- `ffprobe` (part of ffmpeg) - for video metadata extraction

### Installation of Dependencies

#### Debian/Ubuntu
```bash
sudo apt-get update
sudo apt-get install libimage-exiftool-perl ffmpeg
```

#### Fedora/RHEL
```bash
sudo dnf install perl-Image-ExifTool ffmpeg
```

#### Arch Linux
```bash
sudo pacman -S perl-image-exiftool ffmpeg
```

The script will work without these tools but will fall back to file modification times, which may be less accurate.

## Installation

1. Download or clone this script
2. Make it executable:
```bash
chmod +x organize_files_by_year.sh
```

3. Optionally, move it to a directory in your PATH:
```bash
sudo cp organize_files_by_year.sh /usr/local/bin/organize-photos
```

## Usage

### Basic Syntax
```bash
./organize_files_by_year.sh -s SOURCE_DIR -d DEST_DIR [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `-s, --source DIR` | Source directory containing files to organize (required) |
| `-d, --dest DIR` | Destination directory for organized files (required) |
| `-n, --dry-run` | Preview what would happen without moving files |
| `-v, --verbose` | Print detailed information about each file |
| `-l, --log FILE` | Write detailed log to specified file |
| `--skip-duplicates` | Skip files if destination already exists (instead of renaming) |
| `-h, --help` | Show help message |

## Examples

### Example 1: Dry Run (Preview)
First, always do a dry run to see what will happen:

```bash
./organize_files_by_year.sh \
  -s /home/dad/messy_photos \
  -d /home/dad/organized_photos \
  -n -v
```

This will show you what the script would do without actually moving files.

### Example 2: Organize with Logging
Once you're happy with the preview, organize for real and save a log:

```bash
./organize_files_by_year.sh \
  -s /home/dad/messy_photos \
  -d /home/dad/organized_photos \
  -v -l organize.log
```

### Example 3: Organize Files from USB Drive
```bash
./organize_files_by_year.sh \
  -s /media/usb_drive/photos \
  -d /home/dad/photos_by_year \
  -v
```

### Example 4: Skip Duplicates Instead of Renaming
```bash
./organize_files_by_year.sh \
  -s /home/dad/mixed_files \
  -d /home/dad/sorted_files \
  --skip-duplicates -v
```

## How It Works

### Date Extraction Priority

For each file, the script tries to extract the year in this order:

1. **EXIF Data** (for images: JPG, PNG, TIFF, RAW formats, HEIC, etc.)
   - Tries: DateTimeOriginal, CreateDate, DateTimeDigitized
   - Most accurate for photos from cameras and phones

2. **Video Metadata** (for videos: MP4, MOV, AVI, MKV, etc.)
   - Extracts creation_time from container metadata
   - Accurate for most video files

3. **File Timestamp** (fallback for all files)
   - Uses file modification date
   - Less accurate as it changes when file is copied/moved

### Duplicate Handling

When a file with the same name already exists in the destination:

- **Default behavior**: Renames the new file by adding a counter
  - Example: `photo.jpg` → `photo_1.jpg`, `photo_2.jpg`, etc.

- **With `--skip-duplicates`**: Skips the file entirely
  - Useful if you've already organized some files

### Output Structure

Files are organized into year folders:
```
destination/
├── 2020/
│   ├── photo1.jpg
│   ├── video1.mp4
│   └── document.pdf
├── 2021/
│   ├── photo2.jpg
│   └── photo3.jpg
├── 2022/
│   └── ...
└── 2023/
    └── ...
```

## Safety Features

1. **Confirmation Prompt**: Asks for confirmation before moving files (unless dry-run)
2. **Path Validation**: Prevents moving files if destination is inside source
3. **Error Handling**: Continues processing even if individual files fail
4. **Statistics**: Shows summary of processed, skipped, and failed files
5. **Logging**: Optional detailed log file for troubleshooting

## Tips for Your Father

### First Time Use
1. **Always start with a dry run** using `-n` to preview what will happen
2. **Use verbose mode** (`-v`) to see what's being done
3. **Keep the original files** until you've verified the organization is correct
4. **Use a log file** (`-l organize.log`) to have a record of what was moved

### Recommended Workflow

```bash
# Step 1: Preview what will happen
./organize_files_by_year.sh -s ~/old_photos -d ~/photos_organized -n -v

# Step 2: If it looks good, do it for real with logging
./organize_files_by_year.sh -s ~/old_photos -d ~/photos_organized -v -l organize.log

# Step 3: Check the organized folder
ls ~/photos_organized/

# Step 4: Review the log if needed
less organize.log
```

### After Running

The script provides statistics showing:
- Total files found
- Successfully processed files
- Skipped files (duplicates)
- Failed files (if any)

## Troubleshooting

### "Could not determine year for file"
- File has no EXIF data and no valid timestamp
- Will use current year as fallback
- Check if exiftool is installed for better metadata extraction

### "Permission denied"
- Make sure you have read access to source files
- Make sure you have write access to destination directory

### Script is slow
- Normal for large collections (thousands of files)
- EXIF extraction takes time but ensures accuracy
- Use `--skip-duplicates` if re-running on partially organized folders

### Files are dated incorrectly
- Without exiftool, the script uses file modification times
- These change when files are copied, so install exiftool for accuracy:
  ```bash
  sudo apt-get install libimage-exiftool-perl
  ```

## Common Issues and Solutions

**Q: The script moved files but used the wrong dates**
- A: Install exiftool and ffprobe for accurate metadata extraction
- Without these tools, only file modification times are used

**Q: I want to organize only photos, not all files**
- A: You can modify the script or use find to filter by extension first

**Q: Can I organize by month instead of year?**
- A: The current script organizes by year. You could modify it to create month folders (e.g., 2023/01/, 2023/02/)

**Q: What if I accidentally moved files to the wrong place?**
- A: Always do a dry run first! If you need to undo, check the log file to see what was moved where

## Technical Details

### Supported File Formats

**Images** (EXIF extraction):
- JPEG (.jpg, .jpeg)
- PNG (.png)
- TIFF (.tif, .tiff)
- RAW formats (.raw, .cr2, .nef, .arw, .dng)
- HEIC/HEIF (.heic, .heif)

**Videos** (metadata extraction):
- MP4 (.mp4, .m4v)
- MOV (.mov)
- AVI (.avi)
- MKV (.mkv)
- 3GP (.3gp)
- MTS/M2TS (.mts, .m2ts)

**All other files**: Uses file modification timestamp

## License

This script is provided as-is for personal use. Feel free to modify and distribute.

## Support

If you encounter issues:
1. Check the log file if you used `-l`
2. Try running with `-v` to see detailed output
3. Make sure dependencies are installed
4. Verify file permissions on source and destination directories
