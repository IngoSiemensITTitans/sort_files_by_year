#!/bin/bash

################################################################################
# File Organization Script by Year
#
# This script recursively scans directories and organizes files by the year
# they were created/taken. It extracts dates from:
# 1. EXIF data (for photos)
# 2. Video metadata (for videos)
# 3. File creation/modification time (fallback)
#
# Handles duplicate filenames by appending numbers.
################################################################################

# Note: We handle errors explicitly in the script, so we don't use set -e
# set -e would cause issues with our error handling in loops

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
SOURCE_DIR=""
DEST_DIR=""
DRY_RUN=false
VERBOSE=false
LOG_FILE=""
SKIP_DUPLICATES=false

# Statistics
TOTAL_FILES=0
PROCESSED_FILES=0
SKIPPED_FILES=0
FAILED_FILES=0

################################################################################
# Functions
################################################################################

print_help() {
    cat << EOF
Usage: $0 -s SOURCE_DIR -d DEST_DIR [OPTIONS]

Required:
  -s, --source DIR      Source directory containing files to organize
  -d, --dest DIR        Destination directory for organized files

Optional:
  -n, --dry-run         Show what would be done without moving files
  -v, --verbose         Print detailed information
  -l, --log FILE        Write log to specified file
  --skip-duplicates     Skip files if destination already exists
  -h, --help            Show this help message

Example:
  $0 -s /home/user/messy_photos -d /home/user/organized -n -v

This will scan /home/user/messy_photos and organize files into:
  /home/user/organized/2023/
  /home/user/organized/2024/
  etc.

EOF
}

log_message() {
    local level="$1"
    local message="$2"
    local color="${NC}"

    case "$level" in
        INFO)  color="${BLUE}" ;;
        SUCCESS) color="${GREEN}" ;;
        WARNING) color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
    esac

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="[${timestamp}] [${level}] ${message}"

    # Print to console with color
    if [[ "$VERBOSE" == true ]] || [[ "$level" == "ERROR" ]] || [[ "$level" == "WARNING" ]]; then
        echo -e "${color}${output}${NC}"
    fi

    # Write to log file without color
    if [[ -n "$LOG_FILE" ]]; then
        echo "$output" >> "$LOG_FILE"
    fi
}

check_dependencies() {
    log_message "INFO" "Checking dependencies..."

    local missing_deps=()

    if ! command -v exiftool &> /dev/null; then
        missing_deps+=("exiftool")
    fi

    if ! command -v ffprobe &> /dev/null; then
        missing_deps+=("ffmpeg (for ffprobe)")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_message "WARNING" "Optional dependencies missing: ${missing_deps[*]}"
        log_message "WARNING" "Will fall back to file modification times for affected files"
        log_message "INFO" "To install: sudo apt-get install libimage-exiftool-perl ffmpeg"
    else
        log_message "SUCCESS" "All dependencies available"
    fi
}

# Extract year from EXIF data (photos)
get_year_from_exif() {
    local file="$1"

    if ! command -v exiftool &> /dev/null; then
        return 1
    fi

    # Try multiple EXIF date fields in order of preference
    local date_fields=(
        "DateTimeOriginal"
        "CreateDate"
        "DateTimeDigitized"
        "MediaCreateDate"
        "TrackCreateDate"
        "FileModifyDate"
    )

    for field in "${date_fields[@]}"; do
        local exif_date=$(exiftool -s -s -s -"$field" "$file" 2>/dev/null)
        if [[ -n "$exif_date" ]]; then
            # Extract year from various date formats
            # Format: "2023:01:15 12:30:45" or "2023-01-15 12:30:45" or "2023"
            local year=$(echo "$exif_date" | grep -oP '^\d{4}' | head -1)
            if [[ "$year" =~ ^[0-9]{4}$ ]] && [ "$year" -ge 1970 ] && [ "$year" -le $(date +%Y) ]; then
                echo "$year"
                return 0
            fi
        fi
    done

    return 1
}

# Extract year from video metadata
get_year_from_video() {
    local file="$1"

    if ! command -v ffprobe &> /dev/null; then
        return 1
    fi

    # Try to get creation_time from video metadata
    local creation_time=$(ffprobe -v quiet -show_entries format_tags=creation_time -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)

    if [[ -n "$creation_time" ]]; then
        local year=$(echo "$creation_time" | grep -oP '^\d{4}' | head -1)
        if [[ "$year" =~ ^[0-9]{4}$ ]] && [ "$year" -ge 1970 ] && [ "$year" -le $(date +%Y) ]; then
            echo "$year"
            return 0
        fi
    fi

    return 1
}

# Extract year from file modification time (fallback)
get_year_from_file_stat() {
    local file="$1"

    # Get modification time and extract year
    local year=$(stat -c %y "$file" 2>/dev/null | cut -d'-' -f1)

    if [[ "$year" =~ ^[0-9]{4}$ ]] && [ "$year" -ge 1970 ] && [ "$year" -le $(date +%Y) ]; then
        echo "$year"
        return 0
    fi

    # Fallback to current year if all else fails
    echo $(date +%Y)
    return 0
}

# Determine year for a file
get_file_year() {
    local file="$1"
    local year=""
    local method=""

    # Get file extension
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # Try EXIF first for common image/video formats
    case "$ext" in
        jpg|jpeg|png|tiff|tif|raw|cr2|nef|arw|dng|heic|heif)
            year=$(get_year_from_exif "$file")
            if [[ -n "$year" ]]; then
                method="EXIF"
            fi
            ;;
        mp4|mov|avi|mkv|m4v|3gp|mts|m2ts)
            year=$(get_year_from_video "$file")
            if [[ -n "$year" ]]; then
                method="Video metadata"
            else
                year=$(get_year_from_exif "$file")
                if [[ -n "$year" ]]; then
                    method="EXIF"
                fi
            fi
            ;;
    esac

    # Fallback to file stat if no metadata found
    if [[ -z "$year" ]]; then
        year=$(get_year_from_file_stat "$file")
        method="File timestamp"
    fi

    echo "$year|$method"
}

# Get unique filename if file exists
get_unique_filename() {
    local dest_dir="$1"
    local filename="$2"
    local basename="${filename%.*}"
    local extension="${filename##*.}"

    # If no extension, handle differently
    if [[ "$basename" == "$extension" ]]; then
        extension=""
        basename="$filename"
    fi

    local counter=1
    local new_filename="$filename"

    while [[ -e "$dest_dir/$new_filename" ]]; do
        if [[ -n "$extension" ]]; then
            new_filename="${basename}_${counter}.${extension}"
        else
            new_filename="${basename}_${counter}"
        fi
        ((counter++))
    done

    echo "$new_filename"
}

# Process a single file
process_file() {
    local file="$1"
    ((TOTAL_FILES++))

    log_message "INFO" "Processing: $file"

    # Get year and method
    local year_info=$(get_file_year "$file")
    local year=$(echo "$year_info" | cut -d'|' -f1)
    local method=$(echo "$year_info" | cut -d'|' -f2)

    if [[ -z "$year" ]]; then
        log_message "ERROR" "Could not determine year for: $file"
        ((FAILED_FILES++))
        return 1
    fi

    log_message "INFO" "  Year: $year (from $method)"

    # Create destination directory
    local year_dir="${DEST_DIR}/${year}"

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$year_dir"
    fi

    # Get filename
    local filename=$(basename "$file")
    local dest_file="${year_dir}/${filename}"

    # Check if file already exists and handle accordingly
    if [[ -e "$dest_file" ]] && [[ "$DRY_RUN" == false ]]; then
        if [[ "$SKIP_DUPLICATES" == true ]]; then
            log_message "WARNING" "  Skipping (already exists): $dest_file"
            ((SKIPPED_FILES++))
            return 0
        else
            # Get unique filename
            filename=$(get_unique_filename "$year_dir" "$filename")
            dest_file="${year_dir}/${filename}"
            log_message "INFO" "  Renamed to avoid conflict: $filename"
        fi
    fi

    # Move or simulate move
    if [[ "$DRY_RUN" == true ]]; then
        log_message "SUCCESS" "  Would move to: $dest_file"
        ((PROCESSED_FILES++))
    else
        if mv "$file" "$dest_file"; then
            log_message "SUCCESS" "  Moved to: $dest_file"
            ((PROCESSED_FILES++))
        else
            log_message "ERROR" "  Failed to move: $file"
            ((FAILED_FILES++))
            return 1
        fi
    fi

    return 0
}

# Process directory recursively
process_directory() {
    local dir="$1"

    log_message "INFO" "Scanning directory: $dir"

    # Use find to get all files recursively
    # -type f: only files, not directories
    # Process files in sorted order
    while IFS= read -r file; do
        # Skip if file is in destination directory (avoid processing already organized files)
        if [[ "$file" == "$DEST_DIR"* ]]; then
            log_message "INFO" "Skipping file in destination directory: $file"
            continue
        fi

        process_file "$file"
    done < <(find "$dir" -type f | sort)
}

# Print statistics
print_statistics() {
    echo ""
    echo "=================================================="
    echo "                  STATISTICS"
    echo "=================================================="
    echo "Total files found:     $TOTAL_FILES"
    echo "Successfully processed: $PROCESSED_FILES"
    echo "Skipped:               $SKIPPED_FILES"
    echo "Failed:                $FAILED_FILES"
    echo "=================================================="

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo "This was a DRY RUN - no files were actually moved."
        echo "Run without -n flag to perform the actual operation."
    fi
}

################################################################################
# Main Script
################################################################################

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        -d|--dest)
            DEST_DIR="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        --skip-duplicates)
            SKIP_DUPLICATES=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SOURCE_DIR" ]] || [[ -z "$DEST_DIR" ]]; then
    echo -e "${RED}Error: Source and destination directories are required${NC}"
    echo ""
    print_help
    exit 1
fi

# Validate source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo -e "${RED}Error: Source directory does not exist: $SOURCE_DIR${NC}"
    exit 1
fi

# Convert to absolute paths
SOURCE_DIR=$(realpath "$SOURCE_DIR")
DEST_DIR=$(realpath "$DEST_DIR")

# Check if source and dest are the same
if [[ "$SOURCE_DIR" == "$DEST_DIR" ]]; then
    echo -e "${RED}Error: Source and destination directories cannot be the same${NC}"
    exit 1
fi

# Check if dest is inside source (would cause issues)
if [[ "$DEST_DIR" == "$SOURCE_DIR"* ]]; then
    echo -e "${RED}Error: Destination directory cannot be inside source directory${NC}"
    exit 1
fi

# Create destination directory if it doesn't exist
if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$DEST_DIR"
fi

# Initialize log file
if [[ -n "$LOG_FILE" ]]; then
    LOG_FILE=$(realpath "$LOG_FILE")
    echo "File Organization Log - $(date)" > "$LOG_FILE"
    echo "Source: $SOURCE_DIR" >> "$LOG_FILE"
    echo "Destination: $DEST_DIR" >> "$LOG_FILE"
    echo "Dry Run: $DRY_RUN" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
fi

# Print configuration
echo "=================================================="
echo "      File Organization Script"
echo "=================================================="
echo "Source:      $SOURCE_DIR"
echo "Destination: $DEST_DIR"
echo "Dry Run:     $DRY_RUN"
echo "Verbose:     $VERBOSE"
echo "Log File:    ${LOG_FILE:-None}"
echo "=================================================="
echo ""

# Check dependencies
check_dependencies
echo ""

# Confirm before proceeding (unless dry run)
if [[ "$DRY_RUN" == false ]]; then
    read -p "Proceed with file organization? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

# Process all files
log_message "INFO" "Starting file organization..."
process_directory "$SOURCE_DIR"

# Print statistics
print_statistics

log_message "INFO" "File organization complete!"

exit 0
