#!/bin/bash
# Ensure we're running in bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi
# Paths and variables
INGEST_DIR="/workspace/ingest"  # Directory containing the input images or videos
COLMAP_WORKSPACE="/workspace/colmap_workspace"  # COLMAP output directory
NERFSTUDIO_OUTPUT="/workspace/nerfstudio_dataset"  # Brush dataset directory

DB_PATH="$COLMAP_WORKSPACE/database.db"  # Path to COLMAP database
UNDISTORTED_DIR="$COLMAP_WORKSPACE/undistorted"  # Directory for undistorted images
IMAGE_DIR="$COLMAP_WORKSPACE/images"  # Organized image directory
SPARSE_DIR="$COLMAP_WORKSPACE/sparse"  # Sparse reconstruction directory
DENSE_DIR="$COLMAP_WORKSPACE/dense"  # Dense reconstruction directory
CURRENT_DATE=$(date +"%Y-%m-%d")

# Enhanced GPU detection that works in containers
detect_gpu() {
    # First try nvidia-smi (requires --gpus flag or NVIDIA runtime)
    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi -L &>/dev/null; then  # More reliable check
            echo "NVIDIA GPU detected via nvidia-smi"
            return 0
        fi
    fi

    # Check for NVIDIA devices in /dev
    if [ -e /dev/nvidia0 ] || [ -e /dev/nvidia-uvm ] || [ -e /dev/nvidiactl ]; then
        echo "NVIDIA GPU devices detected in /dev"
        return 0
    fi

    # Check for NVIDIA runtime (common in Docker)
    if [ -f /.dockerenv ] && [ -n "$NVIDIA_VISIBLE_DEVICES" ]; then
        echo "NVIDIA GPU allocated via Docker runtime"
        return 0
    fi

    # Fallback to CUDA library check
    if ldconfig -p | grep -q libcuda.so || [ -f /usr/local/cuda/version.txt ]; then
        echo "CUDA libraries detected"
        return 0
    fi

    echo "No compatible GPU detected"
    return 1
}

# Set USE_GPU based on detection
if detect_gpu; then
    USE_GPU=true
    export USE_GPU  # Make available to subprocesses
    echo "GPU acceleration enabled"
else
    USE_GPU=false
    export USE_GPU
    echo "CUDA acceleration disabled - using CPU only for reconstruction"
fi

# Create necessary directories at start
mkdir -p "$IMAGE_DIR" "$SPARSE_DIR" "$DENSE_DIR" "$UNDISTORTED_DIR"

# Function to check if processing is needed
needs_processing() {
    local step=$1
    local check_file=$2

    if [ -f "$COLMAP_WORKSPACE/.processed_$step" ]; then
        return 1  # Already processed
    fi

    if [ -n "$check_file" ] && [ ! -e "$check_file" ]; then
        return 0  # Needs processing
    fi

    return 0  # Default to needing processing
}

# Function to mark step as completed
mark_processed() {
    local step=$1
    touch "$COLMAP_WORKSPACE/.processed_$step"
}

# Check if we can skip straight to brush
if [ -d "$SPARSE_DIR" ] && [ -n "$(ls -A "$SPARSE_DIR")" ]; then
    echo "Found existing sparse reconstruction, proceeding directly to brush..."
    brush "$COLMAP_WORKSPACE" --export-every 500 --eval-save-to-disk --export-path /workspace/out
    exit 0
fi

# Check if ingest folder exists
if [ ! -d "$INGEST_DIR" ]; then
    echo "Error: Ingest directory $INGEST_DIR does not exist!"
    exit 1
fi

# Function to extract frames from video using ffmpeg
extract_frames() {
    local video_file="$1"
    local output_dir="$2"
    local frame_rate=1  # Extract 1 frame per second (adjust as needed)

    echo "Extracting frames from $video_file to $output_dir..."
    ffmpeg -i "$video_file" -r $frame_rate "$output_dir/frame_%04d.jpg"
}

# Convert non-JPEG images to JPEG if needed
if needs_processing "image_conversion"; then
    echo "Converting non-JPEG images to JPG..."
    find "$INGEST_DIR" -type f \( -iname "*.webp" -o -iname "*.gif" -o -iname "*.heif" -o -iname "*.heic" -o -iname "*.bmp" \) | while read -r file; do
        convert "$file" -quality 100% -format jpg "${file%.*}.jpg"
    done
    mark_processed "image_conversion"
fi

# Process video files in the ingest directory if needed
if needs_processing "video_extraction" "$IMAGE_DIR/frame_0001.jpg"; then
    echo "Checking for video files in $INGEST_DIR..."
    find "$INGEST_DIR" -type f \( -iname "*.mp4" -o -iname "*.mov" \) | while read -r video_file; do
        extract_frames "$video_file" "$IMAGE_DIR"
    done
    mark_processed "video_extraction"
fi

# Move JPEG files from ingest directory to the image directory if needed
if needs_processing "image_organization" "$IMAGE_DIR"; then
    echo "Organizing images from $INGEST_DIR..."
    find "$INGEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.JPG" -o -iname "*.png" \) -exec cp {} "$IMAGE_DIR" \;
    mark_processed "image_organization"
fi

# Check if any images were moved or extracted
if [ "$(ls -A $IMAGE_DIR 2>/dev/null)" = "" ]; then
    echo "Error: No JPEG files or video files found in $INGEST_DIR."
    exit 1
fi

# Initialize COLMAP database if it doesn't exist
if needs_processing "database_creation" "$DB_PATH"; then
    echo "Creating a new COLMAP database at $DB_PATH..."
    colmap database_creator --database_path "$DB_PATH"
    mark_processed "database_creation"
fi

# Run feature extraction if needed
if needs_processing "feature_extraction" "$DB_PATH"; then
    echo "Running feature extraction with COLMAP..."
    if [ "$USE_GPU" = true ]; then
        case "$RENDER_PIPELINE" in
            "fast")
                PEAK_THRESHOLD=0.02
                MAX_FEATURES=1000
                ;;
            "high_quality")
                PEAK_THRESHOLD=0.008
                MAX_FEATURES=8000
                ;;
            *)
                PEAK_THRESHOLD=0.01
                MAX_FEATURES=5000
                ;;
        esac

        colmap feature_extractor \
            --database_path "$DB_PATH" \
            --image_path "$IMAGE_DIR" \
            --ImageReader.camera_model PINHOLE \
            --SiftExtraction.peak_threshold $PEAK_THRESHOLD \
            --SiftExtraction.max_num_features $MAX_FEATURES \
            --SiftExtraction.max_image_size 2000 \
            --SiftExtraction.use_gpu true
    else
        colmap feature_extractor \
            --database_path "$DB_PATH" \
            --image_path "$IMAGE_DIR" \
            --ImageReader.camera_model PINHOLE \
            --SiftExtraction.peak_threshold 0.01 \
            --SiftExtraction.max_num_features 5000 \
            --SiftExtraction.max_image_size 2000 \
            --SiftExtraction.use_gpu false
    fi
    mark_processed "feature_extraction"
fi

if needs_processing "feature_matching" "$DB_PATH"; then
    echo "Running feature matching..."
    
    if [ "$USE_GPU" = true ]; then
        colmap exhaustive_matcher \
            --database_path "$DB_PATH" \
            --SiftMatching.use_gpu true
    else
        colmap exhaustive_matcher \
            --database_path "$DB_PATH" \
            --SiftMatching.use_gpu false
    fi
fi
# Run sparse reconstruction if needed
if needs_processing "sparse_reconstruction" "$SPARSE_DIR/0"; then
    echo "Running sparse reconstruction (mapping)..."

    case "$SCALE" in
        "large")
            echo "Using COLMAP mapper"
            colmap mapper \
                --database_path "$DB_PATH" \
                --image_path "$IMAGE_DIR" \
                --output_path "$SPARSE_DIR" \
                --Mapper.ba_refine_principal_point 1
            ;;
        *)
            echo "Using GLOMAP mapper"
            glomap mapper \
                --database_path "$DB_PATH" \
                --image_path "$IMAGE_DIR" \
                --output_path "$SPARSE_DIR"
            ;;
    esac

    mark_processed "sparse_reconstruction"
fi

# Always run brush at the end
echo "Running brush on Dataset"
brush "$COLMAP_WORKSPACE" --export-every 500 --eval-save-to-disk --export-path "/workspace/out"
