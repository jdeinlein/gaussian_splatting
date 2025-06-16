#!/bin/bash
# COLMAP 3D Reconstruction Pipeline with CLI and Daemon Modes
# Version 2.0 - Enhanced Feature Extraction

# Ensure we're running in bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# Default paths and variables
INGEST_DIR="/workspace/ingest"
COLMAP_WORKSPACE="/workspace/colmap_workspace"
NERFSTUDIO_OUTPUT="/workspace/nerfstudio_dataset"
MODE="batch"
CONFIG_FILE=""
USE_GPU="auto"
RENDER_PIPELINE="default"
SCALE="default"
DAEMON_INTERVAL=10
JSON_CONFIG=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--daemon)
            MODE="daemon"
            shift
            ;;
        -b|--batch)
            MODE="batch"
            shift
            ;;
        --ingest-dir)
            INGEST_DIR="$2"
            shift 2
            ;;
        --colmap-workspace)
            COLMAP_WORKSPACE="$2"
            shift 2
            ;;
        --nerfstudio-output)
            NERFSTUDIO_OUTPUT="$2"
            shift 2
            ;;
        --gpu)
            if [[ "$2" == "true" || "$2" == "false" ]]; then
                USE_GPU="$2"
            else
                echo "Invalid value for --gpu: $2. Must be 'true' or 'false'."
                exit 1
            fi
            shift 2
            ;;
        --render-pipeline)
            RENDER_PIPELINE="$2"
            shift 2
            ;;
        --scale)
            SCALE="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --daemon-interval)
            DAEMON_INTERVAL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -d, --daemon         Run in daemon mode (continuous processing)"
            echo "  -b, --batch          Run in batch mode (single processing)"
            echo "  --ingest-dir DIR     Set ingest directory"
            echo "  --colmap-workspace DIR  Set COLMAP workspace"
            echo "  --nerfstudio-output DIR Set NeRFstudio output directory"
            echo "  --gpu true|false     Force enable/disable GPU"
            echo "  --render-pipeline PIPELINE  Set render pipeline (fast/high_quality/default)"
            echo "  --scale SCALE        Set scale (large/default)"
            echo "  --config FILE        JSON configuration file"
            echo "  --daemon-interval SEC  Daemon mode check interval (default: 10)"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load JSON configuration if provided
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from $CONFIG_FILE"
    JSON_CONFIG=$(cat "$CONFIG_FILE")
    # Parse JSON using jq if available
    if command -v jq &> /dev/null; then
        INGEST_DIR=$(jq -r '.ingest_dir // empty' <<< "$JSON_CONFIG" || echo "$INGEST_DIR")
        COLMAP_WORKSPACE=$(jq -r '.colmap_workspace // empty' <<< "$JSON_CONFIG" || echo "$COLMAP_WORKSPACE")
        NERFSTUDIO_OUTPUT=$(jq -r '.nerfstudio_output // empty' <<< "$JSON_CONFIG" || echo "$NERFSTUDIO_OUTPUT")
        USE_GPU=$(jq -r '.use_gpu // empty' <<< "$JSON_CONFIG" || echo "$USE_GPU")
        RENDER_PIPELINE=$(jq -r '.render_pipeline // empty' <<< "$JSON_CONFIG" || echo "$RENDER_PIPELINE")
        SCALE=$(jq -r '.scale // empty' <<< "$JSON_CONFIG" || echo "$SCALE")
    else
        echo "Warning: jq not installed. Using basic JSON parsing."
        INGEST_DIR=$(grep -oP '"ingest_dir"\s*:\s*"\K[^"]+' "$CONFIG_FILE" || echo "$INGEST_DIR")
        COLMAP_WORKSPACE=$(grep -oP '"colmap_workspace"\s*:\s*"\K[^"]+' "$CONFIG_FILE" || echo "$COLMAP_WORKSPACE")
        NERFSTUDIO_OUTPUT=$(grep -oP '"nerfstudio_output"\s*:\s*"\K[^"]+' "$CONFIG_FILE" || echo "$NERFSTUDIO_OUTPUT")
        USE_GPU=$(grep -oP '"use_gpu"\s*:\s*\K(true|false)' "$CONFIG_FILE" || echo "$USE_GPU")
        RENDER_PIPELINE=$(grep -oP '"render_pipeline"\s*:\s*"\K[^"]+' "$CONFIG_FILE" || echo "$RENDER_PIPELINE")
        SCALE=$(grep -oP '"scale"\s*:\s*"\K[^"]+' "$CONFIG_FILE" || echo "$SCALE")
    fi
fi

# Internal paths
DB_PATH="$COLMAP_WORKSPACE/database.db"
UNDISTORTED_DIR="$COLMAP_WORKSPACE/undistorted"
IMAGE_DIR="$COLMAP_WORKSPACE/images"
SPARSE_DIR="$COLMAP_WORKSPACE/sparse"
DENSE_DIR="$COLMAP_WORKSPACE/dense"
CURRENT_DATE=$(date +"%Y-%m-%d")

# Enhanced GPU detection
detect_gpu() {
    if [[ "$USE_GPU" == "true" ]]; then return 0; fi
    if [[ "$USE_GPU" == "false" ]]; then return 1; fi

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

# Processing functions
needs_processing() {
    local step=$1
    local check_file=$2
    [ -f "$COLMAP_WORKSPACE/.processed_$step" ] && return 1
    [ -n "$check_file" ] && [ ! -e "$check_file" ] && return 0
    return 0
}

mark_processed() {
    local step=$1
    touch "$COLMAP_WORKSPACE/.processed_$step"
}

# Function to extract frames from video
extract_frames() {
    local video_file="$1"
    local output_dir="$2"
    local frame_rate=1  # Extract 1 frame per second
    
    echo "Extracting frames from $video_file to $output_dir..."
    ffmpeg -i "$video_file" -r $frame_rate "$output_dir/frame_%04d.jpg"
}

# Main processing function
process_data() {
    echo "Starting processing in ${MODE} mode"
    echo "Ingest Dir: $INGEST_DIR"
    echo "COLMAP Workspace: $COLMAP_WORKSPACE"
    echo "NeRF Output: $NERFSTUDIO_OUTPUT"
    echo "Render Pipeline: $RENDER_PIPELINE"
    echo "Scale: $SCALE"

    # Create directories
    mkdir -p "$IMAGE_DIR" "$SPARSE_DIR" "$DENSE_DIR" "$UNDISTORTED_DIR"

    # GPU detection
    if detect_gpu; then
        USE_GPU=true
        echo "GPU acceleration enabled"
    else
        USE_GPU=false
        echo "CUDA acceleration disabled - using CPU only"
    fi
    export USE_GPU

    # Skip to brush if sparse exists
    if [ -d "$SPARSE_DIR" ] && [ -n "$(ls -A "$SPARSE_DIR")" ]; then
        echo "Found existing sparse reconstruction, proceeding to brush..."
        brush "$COLMAP_WORKSPACE" \
            --export-every 500 \
            --eval-save-to-disk \
            --export-path "$NERFSTUDIO_OUTPUT"
        return 0
    fi

    # Check ingest directory
    if [ ! -d "$INGEST_DIR" ]; then
        echo "Error: Ingest directory $INGEST_DIR does not exist!"
        return 1
    fi

    # Image conversion
    if needs_processing "image_conversion"; then
        echo "Converting non-JPEG images to JPG..."
        find "$INGEST_DIR" -type f \( -iname "*.webp" -o -iname "*.gif" -o -iname "*.heif" -o -iname "*.heic" -o -iname "*.bmp" \) -print0 | 
            xargs -0 -P $(nproc) -I{} convert "{}" -quality 100% -format jpg "{}.jpg"
        mark_processed "image_conversion"
    fi

    # Video extraction
    if needs_processing "video_extraction" "$IMAGE_DIR/frame_0001.jpg"; then
        echo "Extracting frames from videos..."
        find "$INGEST_DIR" -type f \( -iname "*.mp4" -o -iname "*.mov" \) -print0 |
            xargs -0 -P $(nproc) -I{} ffmpeg -i "{}" -r 1 "$IMAGE_DIR/frame_%04d.jpg"
        mark_processed "video_extraction"
    fi

    # Image organization
    if needs_processing "image_organization" "$IMAGE_DIR"; then
        echo "Organizing images..."
        find "$INGEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.JPG" -o -iname "*.png" \) -exec cp {} "$IMAGE_DIR" \;
        mark_processed "image_organization"
    fi

    # Check for images
    if [ -z "$(ls -A "$IMAGE_DIR")" ]; then
        echo "Error: No images found in $IMAGE_DIR!"
        return 1
    fi

    # Database creation
    if needs_processing "database_creation" "$DB_PATH"; then
        echo "Creating COLMAP database..."
        colmap database_creator --database_path "$DB_PATH"
        mark_processed "database_creation"
    fi

    # Feature extraction with quality presets
    if needs_processing "feature_extraction" "$DB_PATH"; then
        echo "Running feature extraction with COLMAP..."
        
        # Set default parameters
        local PEAK_THRESHOLD=0.01
        local MAX_FEATURES=5000
        
        # GPU-specific quality presets
        if [ "$USE_GPU" = true ]; then
            case "$RENDER_PIPELINE" in
                "fast")
                    PEAK_THRESHOLD=0.02
                    MAX_FEATURES=1000
                    echo "Using fast pipeline: threshold=0.02, max_features=1000"
                    ;;
                "high_quality")
                    PEAK_THRESHOLD=0.008
                    MAX_FEATURES=8000
                    echo "Using high quality pipeline: threshold=0.008, max_features=8000"
                    ;;
                *)
                    echo "Using default pipeline: threshold=0.01, max_features=5000"
                    ;;
            esac
        else
            echo "Using CPU defaults: threshold=0.01, max_features=5000"
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

    # Feature matching
    if needs_processing "feature_matching" "$DB_PATH"; then
        echo "Running feature matching..."
        colmap exhaustive_matcher \
            --database_path "$DB_PATH" \
            --SiftMatching.use_gpu $USE_GPU
        mark_processed "feature_matching"
    fi

    # Sparse reconstruction
    if needs_processing "sparse_reconstruction" "$SPARSE_DIR/0"; then
        echo "Running sparse reconstruction..."
        case "$SCALE" in
            "large")
                echo "Using COLMAP mapper for large scenes"
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

    # Final processing with Brush
    echo "Running Brush for NeRF dataset generation..."
    brush "$COLMAP_WORKSPACE" \
        --export-every 500 \
        --eval-save-to-disk \
        --enable-rerun \
        --export-path "$NERFSTUDIO_OUTPUT"
}

# Daemon mode
run_daemon() {
    echo "Starting in daemon mode. Checking every $DAEMON_INTERVAL seconds."
    while true; do
        if [ -n "$(ls -A "$INGEST_DIR" 2>/dev/null)" ]; then
            echo "New data detected in $INGEST_DIR, starting processing..."
            process_data
            echo "Processing complete. Resetting for next batch."
            rm -f "$COLMAP_WORKSPACE"/.processed_*
            mv "$INGEST_DIR"/* "$INGEST_DIR/processed_$(date +%s)/" 2>/dev/null
        else
            sleep "$DAEMON_INTERVAL"
        fi
    done
}

# Execution based on mode
case "$MODE" in
    "daemon")
        run_daemon
        ;;
    "batch")
        process_data
        ;;
    *)
        echo "Invalid mode: $MODE"
        exit 1
        ;;
esac