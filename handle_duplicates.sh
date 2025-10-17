#!/bin/bash

################################################################################
# Duplicate File Handler Script
#
# This script finds duplicate files (with patterns like _1, _2, (1), (2))
# and moves lower quality duplicates to a separate folder, keeping the best
# quality version in the original location.
#
# Quality ranking:
# 1. Resolution (width × height) for images/videos
# 2. Bitrate for videos (if resolution is same)
# 3. File size (fallback)
# 4. For exact duplicates (same hash): keep oldest
################################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
SOURCE_DIR=""
DUPLICATES_DIR=""
DRY_RUN=false
VERBOSE=false
LOG_FILE=""
USE_HASH=true

# Statistics
TOTAL_FILES=0
DUPLICATE_GROUPS=0
FILES_MOVED=0
FILES_KEPT=0

################################################################################
# Functions
################################################################################

print_help() {
    cat << EOF
Usage: $0 -s SOURCE_DIR [OPTIONS]

Required:
  -s, --source DIR      Source directory containing files with duplicates

Optional:
  -o, --output DIR      Duplicates output directory (default: SOURCE_DIR/duplicates)
  -n, --dry-run         Show what would be done without moving files
  -v, --verbose         Print detailed information
  -l, --log FILE        Write log to specified file
  --no-hash             Skip hash-based exact duplicate detection (faster)
  -h, --help            Show this help message

Example:
  $0 -s /home/user/organized -n -v

This will:
  - Find duplicates like: photo.jpg, photo_1.jpg, photo (1).jpg
  - Keep the best quality version in place
  - Move duplicates to /home/user/organized/duplicates/

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
    if [[ "$VERBOSE" == true ]] || [[ "$level" == "ERROR" ]] || [[ "$level" == "WARNING" ]] || [[ "$level" == "SUCCESS" ]]; then
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

    if ! command -v md5sum &> /dev/null; then
        missing_deps+=("md5sum")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_message "WARNING" "Optional dependencies missing: ${missing_deps[*]}"
        log_message "WARNING" "Will use fallback methods for affected operations"
    else
        log_message "SUCCESS" "All dependencies available"
    fi
}

# Normalize filename to detect duplicates
# Examples:
#   photo.jpg -> photo.jpg
#   photo_1.jpg -> photo.jpg
#   photo (1).jpg -> photo.jpg
#   photo_git_2.jpg -> photo_git_2.jpg (keep meaningful suffixes)
normalize_filename() {
    local filename="$1"
    local basename="${filename%.*}"
    local extension="${filename##*.}"

    # If no extension
    if [[ "$basename" == "$extension" ]]; then
        extension=""
        basename="$filename"
    fi

    # Remove Windows-style duplicates: " (1)", " (2)", etc.
    basename=$(echo "$basename" | sed -E 's/ \([0-9]+\)$//')

    # Remove script-generated duplicates: "_1", "_2", etc. (only at the end)
    basename=$(echo "$basename" | sed -E 's/_[0-9]+$//')

    # Reconstruct filename
    if [[ -n "$extension" ]]; then
        echo "${basename}.${extension}"
    else
        echo "${basename}"
    fi
}

# Get image resolution (pixels)
get_image_resolution() {
    local file="$1"

    if ! command -v exiftool &> /dev/null; then
        return 1
    fi

    local width=$(exiftool -s -s -s -ImageWidth "$file" 2>/dev/null)
    local height=$(exiftool -s -s -s -ImageHeight "$file" 2>/dev/null)

    if [[ -n "$width" ]] && [[ -n "$height" ]] && [[ "$width" =~ ^[0-9]+$ ]] && [[ "$height" =~ ^[0-9]+$ ]]; then
        echo $((width * height))
        return 0
    fi

    return 1
}

# Get video resolution and bitrate
get_video_quality() {
    local file="$1"

    if ! command -v ffprobe &> /dev/null; then
        return 1
    fi

    # Get width, height, and bitrate
    local width=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    local height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    local bitrate=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)

    if [[ -n "$width" ]] && [[ -n "$height" ]] && [[ "$width" =~ ^[0-9]+$ ]] && [[ "$height" =~ ^[0-9]+$ ]]; then
        local pixels=$((width * height))
        local bitrate_val="${bitrate:-0}"
        # Return format: pixels|bitrate
        echo "${pixels}|${bitrate_val}"
        return 0
    fi

    return 1
}

# Get file quality metric
get_file_quality() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # Try to get resolution based on file type
    case "$ext" in
        jpg|jpeg|png|tiff|tif|raw|cr2|nef|arw|dng|heic|heif|gif|bmp|webp)
            local pixels=$(get_image_resolution "$file")
            if [[ -n "$pixels" ]]; then
                echo "pixels:${pixels}"
                return 0
            fi
            ;;
        mp4|mov|avi|mkv|m4v|3gp|mts|m2ts|wmv|flv|webm)
            local quality=$(get_video_quality "$file")
            if [[ -n "$quality" ]]; then
                echo "video:${quality}"
                return 0
            fi
            ;;
    esac

    # Fallback: use file size
    local size=$(stat -c %s "$file" 2>/dev/null)
    if [[ -n "$size" ]]; then
        echo "size:${size}"
        return 0
    fi

    echo "size:0"
    return 1
}

# Get file hash
get_file_hash() {
    local file="$1"

    if ! command -v md5sum &> /dev/null; then
        return 1
    fi

    md5sum "$file" 2>/dev/null | cut -d' ' -f1
}

# Compare two files and return which is better
# Returns: 1 if first is better, 2 if second is better, 0 if equal
compare_files() {
    local file1="$1"
    local file2="$2"

    # Get quality metrics
    local quality1=$(get_file_quality "$file1")
    local quality2=$(get_file_quality "$file2")

    local type1=$(echo "$quality1" | cut -d: -f1)
    local type2=$(echo "$quality2" | cut -d: -f1)

    # If using hash and types match, check if files are identical
    if [[ "$USE_HASH" == true ]] && [[ "$type1" == "$type2" ]]; then
        local hash1=$(get_file_hash "$file1")
        local hash2=$(get_file_hash "$file2")

        if [[ -n "$hash1" ]] && [[ -n "$hash2" ]] && [[ "$hash1" == "$hash2" ]]; then
            # Exact duplicates - keep older file
            local mtime1=$(stat -c %Y "$file1")
            local mtime2=$(stat -c %Y "$file2")

            if [[ "$mtime1" -lt "$mtime2" ]]; then
                return 1
            else
                return 2
            fi
        fi
    fi

    # Compare based on type
    if [[ "$type1" == "video" ]] && [[ "$type2" == "video" ]]; then
        local pixels1=$(echo "$quality1" | cut -d: -f2 | cut -d'|' -f1)
        local pixels2=$(echo "$quality2" | cut -d: -f2 | cut -d'|' -f1)
        local bitrate1=$(echo "$quality1" | cut -d: -f2 | cut -d'|' -f2)
        local bitrate2=$(echo "$quality2" | cut -d: -f2 | cut -d'|' -f2)

        if [[ "$pixels1" -gt "$pixels2" ]]; then
            return 1
        elif [[ "$pixels1" -lt "$pixels2" ]]; then
            return 2
        else
            # Same resolution, compare bitrate
            if [[ "$bitrate1" -gt "$bitrate2" ]]; then
                return 1
            elif [[ "$bitrate1" -lt "$bitrate2" ]]; then
                return 2
            fi
        fi
    elif [[ "$type1" == "pixels" ]] && [[ "$type2" == "pixels" ]]; then
        local pixels1=$(echo "$quality1" | cut -d: -f2)
        local pixels2=$(echo "$quality2" | cut -d: -f2)

        if [[ "$pixels1" -gt "$pixels2" ]]; then
            return 1
        elif [[ "$pixels1" -lt "$pixels2" ]]; then
            return 2
        fi
    else
        # Fall back to size comparison
        local size1=$(echo "$quality1" | cut -d: -f2 | cut -d'|' -f1)
        local size2=$(echo "$quality2" | cut -d: -f2 | cut -d'|' -f1)

        if [[ "$size1" -gt "$size2" ]]; then
            return 1
        elif [[ "$size1" -lt "$size2" ]]; then
            return 2
        fi
    fi

    # Equal quality
    return 0
}

# Process a group of duplicate files
process_duplicate_group() {
    local -n files_array=$1
    local base_name="$2"

    if [[ ${#files_array[@]} -lt 2 ]]; then
        return 0
    fi

    ((DUPLICATE_GROUPS++))

    log_message "INFO" "Processing duplicate group: $base_name (${#files_array[@]} files)"

    # Find the best file
    local best_file="${files_array[0]}"
    local best_quality=$(get_file_quality "$best_file")

    for file in "${files_array[@]:1}"; do
        compare_files "$best_file" "$file"
        local result=$?

        if [[ $result -eq 2 ]]; then
            best_file="$file"
            best_quality=$(get_file_quality "$best_file")
        fi
    done

    log_message "SUCCESS" "  Best quality: $best_file"
    log_message "INFO" "  Quality metric: $best_quality"
    ((FILES_KEPT++))

    # Move all other files to duplicates folder
    for file in "${files_array[@]}"; do
        if [[ "$file" == "$best_file" ]]; then
            continue
        fi

        ((TOTAL_FILES++))

        # Determine destination path
        local rel_path="${file#$SOURCE_DIR/}"
        local dir_path=$(dirname "$rel_path")
        local filename=$(basename "$file")

        # Create destination directory structure
        local dest_dir="${DUPLICATES_DIR}/${dir_path}/${base_name}"
        local dest_file="${dest_dir}/${filename}"

        if [[ "$DRY_RUN" == true ]]; then
            log_message "WARNING" "  [DRY RUN] Would move: $file"
            log_message "WARNING" "            -> $dest_file"
            ((FILES_MOVED++))
        else
            mkdir -p "$dest_dir"
            if mv "$file" "$dest_file"; then
                log_message "WARNING" "  Moved duplicate: $file"
                log_message "INFO" "              -> $dest_file"
                ((FILES_MOVED++))
            else
                log_message "ERROR" "  Failed to move: $file"
            fi
        fi
    done
}

# Find and process all duplicates
process_all_duplicates() {
    log_message "INFO" "Scanning for duplicates in: $SOURCE_DIR"

    # Use associative array to group files by normalized name
    declare -A file_groups

    # Find all files
    while IFS= read -r file; do
        local filename=$(basename "$file")
        local dir_path=$(dirname "$file")
        local normalized=$(normalize_filename "$filename")
        local key="${dir_path}/${normalized}"

        # Append to group
        if [[ -n "${file_groups[$key]}" ]]; then
            file_groups[$key]="${file_groups[$key]}|${file}"
        else
            file_groups[$key]="$file"
        fi
    done < <(find "$SOURCE_DIR" -type f ! -path "$DUPLICATES_DIR/*" | sort)

    # Process each group
    for key in "${!file_groups[@]}"; do
        IFS='|' read -ra files <<< "${file_groups[$key]}"

        if [[ ${#files[@]} -gt 1 ]]; then
            local base_name=$(normalize_filename "$(basename "${files[0]}")")
            process_duplicate_group files "$base_name"
        fi
    done
}

# Print statistics
print_statistics() {
    echo ""
    echo "=================================================="
    echo "                  STATISTICS"
    echo "=================================================="
    echo "Duplicate groups found: $DUPLICATE_GROUPS"
    echo "Files kept (best):      $FILES_KEPT"
    echo "Files moved:            $FILES_MOVED"
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
        -o|--output)
            DUPLICATES_DIR="$2"
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
        --no-hash)
            USE_HASH=false
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
if [[ -z "$SOURCE_DIR" ]]; then
    echo -e "${RED}Error: Source directory is required${NC}"
    echo ""
    print_help
    exit 1
fi

# Validate source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo -e "${RED}Error: Source directory does not exist: $SOURCE_DIR${NC}"
    exit 1
fi

# Convert to absolute path
SOURCE_DIR=$(realpath "$SOURCE_DIR")

# Set default duplicates directory if not specified
if [[ -z "$DUPLICATES_DIR" ]]; then
    DUPLICATES_DIR="${SOURCE_DIR}/duplicates"
fi

DUPLICATES_DIR=$(realpath -m "$DUPLICATES_DIR")

# Initialize log file
if [[ -n "$LOG_FILE" ]]; then
    LOG_FILE=$(realpath "$LOG_FILE")
    echo "Duplicate Handler Log - $(date)" > "$LOG_FILE"
    echo "Source: $SOURCE_DIR" >> "$LOG_FILE"
    echo "Duplicates Output: $DUPLICATES_DIR" >> "$LOG_FILE"
    echo "Dry Run: $DRY_RUN" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
fi

# Print configuration
echo "=================================================="
echo "      Duplicate File Handler"
echo "=================================================="
echo "Source:      $SOURCE_DIR"
echo "Duplicates:  $DUPLICATES_DIR"
echo "Dry Run:     $DRY_RUN"
echo "Verbose:     $VERBOSE"
echo "Use Hash:    $USE_HASH"
echo "Log File:    ${LOG_FILE:-None}"
echo "=================================================="
echo ""

# Check dependencies
check_dependencies
echo ""

# Confirm before proceeding (unless dry run)
if [[ "$DRY_RUN" == false ]]; then
    read -p "Proceed with duplicate handling? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

# Create duplicates directory if needed
if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$DUPLICATES_DIR"
fi

# Process all duplicates
log_message "INFO" "Starting duplicate detection and handling..."
process_all_duplicates

# Print statistics
print_statistics

log_message "SUCCESS" "Duplicate handling complete!"

exit 0
