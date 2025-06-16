#!/bin/bash
# Ensure we're running in bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# Default configuration values
INGEST_DIR="/workspace/ingest"
COLMAP_WORKSPACE="/workspace/colmap_workspace"
NERFSTUDIO_OUTPUT="/workspace/nerfstudio_dataset"
FORCE=false
NO_GPU=false
DEBUG=false
FRAME_RATE=1
PEAK_THRESHOLD_ARG=""
MAX_FEATURES_ARG=""
RENDER_PIPELINE=""
SCALE=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -i|--ingest-dir)
        INGEST_DIR="$2"
        shift
        shift
        ;;
        -o|--colmap-workspace)
        COLMAP_WORKSPACE="$2"
        shift
        shift
        ;;
        -n|--nerfstudio-output)
        NERFSTUDIO_OUTPUT="$2"
        shift
        shift
        ;;
        -f|--force)
        FORCE=true
        shift
        ;;
        -g|--no-gpu)
        NO_GPU=true
        shift
        ;;
        -p|--pipeline)
        RENDER_PIPELINE="$2"
        shift
        shift
        ;;
        -s|--scale)
        SCALE="$2"
        shift
        shift
        ;;
        -d|--debug)
        DEBUG=true
        shift
        ;;
        --frame-rate)
        FRAME_RATE="$2"
        shift
        shift
        ;;
        --peak-threshold)
        PEAK_THRESHOLD_ARG="$2"
        shift
        shift
        ;;
        --max-features)
        MAX_FEATURES_ARG="$2"
        shift
        shift
        ;;
        -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  -i, --ingest-dir DIR      Input directory for images/videos (default: /workspace/ingest)"
        echo "  -o, --colmap-workspace DIR COLMAP output directory (default: /workspace/colmap_workspace)"
        echo "  -n, --nerfstudio-output DIR Output directory for NeRFStudio (default: /workspace/nerfstudio_dataset)"
        echo "  -f, --force               Force reprocessing of all steps"
        echo "  -g, --no-gpu              Disable GPU acceleration"
        echo "  -p, --pipeline PIPELINE   Set processing pipeline [fast|high_quality]"
        echo "  -s, --scale SCALE         Set scale for reconstruction [large]"
        echo "  -d, --debug               Enable debug mode"
        echo "  --frame-rate RATE         Frames per second for video extraction (default: 1)"
        echo "  --peak-threshold THRESH   SIFT peak threshold (lower=more features)"
        echo "  --max-features MAX        Max features per image"
        echo "  -h, --help                Show this help"
        exit 0
        ;;
        *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
done

# Paths and variables (using command-line overrides)
DB_PATH="$COLMAP_WORKSPACE/database.db"
UNDISTORTED_DIR="$COLMAP_WORKSPACE/undistorted"
IMAGE_DIR="$COLMAP_WORKSPACE/images"
SPARSE_DIR="$COLMAP_WORKSPACE/sparse"
DENSE_DIR="$COLMAP_WORKSPACE/dense"
CURRENT_DATE=$(date +"%Y-%m-%d")

# Enable debug mode if requested
if [ "$DEBUG" = true ]; then
    set -x
fi

# Create necessary directories
mkdir -p "$IMAGE_DIR" "$SPARSE_DIR" "$DENSE_DIR" "$UNDISTORTED_DIR"

# Enhanced GPU detection that works in containers
detect_gpu() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
        echo "NVIDIA GPU detected via nvidia-smi"
        return 0
    fi
    if [ -e /dev/nvidia0 ] || [ -e /dev/nvidia-uvm ] || [ -e /dev/nvidiactl ]; then
        echo "NVIDIA GPU devices detected in /dev"
        return 0
    fi
    if [ -f /.dockerenv ] && [ -n "$NVIDIA_VISIBLE_DEVICES" ]; then
        echo "NVIDIA GPU allocated via Docker runtime"
        return 0
    fi
    if ldconfig -p | grep -q libcuda.so || [ -f /usr/local/cuda/version.txt ]; then
        echo "CUDA libraries detected"
        return 0
    fi
    echo "No compatible GPU detected"
    return 1
}

# GPU configuration
if [ "$NO_GPU" = true ]; then
    USE_GPU=false
    echo "GPU acceleration disabled by command line"
else
    if detect_gpu; then
        USE_GPU=true
        echo "GPU acceleration enabled"
    else
        USE_GPU=false
        echo "Using CPU only mode"
    fi
fi
export USE_GPU

# Function to check if processing is needed (with force option)
needs_processing() {
    local step=$1
    local check_file=$2

    if [ "$FORCE" = true ]; then
        echo "Force reprocessing step: $step"
        return 0
    fi
    if [ -f "$COLMAP_WORKSPACE/.processed_$step" ]; then
        echo "Step already processed: $step"
        return 1
    fi
    if [ -n "$check_file" ] && [ ! -e "$check_file" ]; then
        echo "Needs processing (missing file): $step"
        return 0
    fi
    return 0
}

# Function to mark step as completed
mark_processed() {
    local step=$1
    touch "$COLMAP_WORKSPACE/.processed_$step"
}

# Check if we can skip straight to brush
if [ -d "$SPARSE_DIR" ] && [ -n "$(ls -A "$SPARSE_DIR")" ] && [ "$FORCE" = false ]; then
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
    local frame_rate="$3"

    echo "Extracting frames from $video_file to $output_dir at ${frame_rate}fps..."
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
        extract_frames "$video_file" "$IMAGE_DIR" "$FRAME_RATE"
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
    
    # Determine parameters
    local PEAK_THRESHOLD="0.01"
    local MAX_FEATURES="5000"
    
    if [ -n "$PEAK_THRESHOLD_ARG" ]; then
        PEAK_THRESHOLD="$PEAK_THRESHOLD_ARG"
    elif [ "$RENDER_PIPELINE" = "fast" ]; then
        PEAK_THRESHOLD="0.02"
        MAX_FEATURES="1000"
    elif [ "$RENDER_PIPELINE" = "high_quality" ]; then
        PEAK_THRESHOLD="0.008"
        MAX_FEATURES="8000"
    fi
    
    if [ -n "$MAX_FEATURES_ARG" ]; then
        MAX_FEATURES="$MAX_FEATURES_ARG"
    fi

    colmap feature_extractor \
        --database_path "$DB_PATH" \
        --image_path "$IMAGE_DIR" \
        --ImageReader.camera_model PINHOLE \
        --SiftExtraction.peak_threshold $PEAK_THRESHOLD \
        --SiftExtraction.max_num_features $MAX_FEATURES \
        --SiftExtraction.max_image_size 2000 \
        --SiftExtraction.use_gpu $USE_GPU
    
    mark_processed "feature_extraction"
fi

# Run feature matching if needed
if needs_processing "feature_matching" "$DB_PATH"; then
    echo "Running feature matching..."
    
    colmap exhaustive_matcher \
        --database_path "$DB_PATH" \
        --SiftMatching.use_gpu $USE_GPU
    
    mark_processed "feature_matching"
fi

# Run sparse reconstruction if needed
if needs_processing "sparse_reconstruction" "$SPARSE_DIR/0"; then
    echo "Running sparse reconstruction..."
    
    if [ "$SCALE" = "large" ]; then
        echo "Using COLMAP mapper for large scale reconstruction"
        colmap mapper \
            --database_path "$DB_PATH" \
            --image_path "$IMAGE_DIR" \
            --output_path "$SPARSE_DIR" \
            --Mapper.ba_refine_principal_point 1
    else
        echo "Using GLOMAP mapper"
        glomap mapper \
            --database_path "$DB_PATH" \
            --image_path "$IMAGE_DIR" \
            --output_path "$SPARSE_DIR"
    fi
    
    mark_processed "sparse_reconstruction"
fi

# Always run brush at the end
echo "Running brush on dataset..."
brush "$COLMAP_WORKSPACE" \
    --export-every 500 \
    --eval-save-to-disk \
    --enable-rerun \
    --export-path "/workspace/out"