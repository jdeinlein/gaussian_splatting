#!/bin/bash
# Mock 3D Pipeline - Testing Version
# Simulates the structure of colmap.sh without heavy dependencies

# Ensure we're running in bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# START LOGGING (Simulated)
LOG_FILE="./test_process.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "--- Mock Pipeline started at $(date) ---"

# Default paths and variables
INGEST_DIR="./test_ingest"
COLMAP_WORKSPACE="./test_workspace"
MODE="batch"
USE_GPU="auto"
RENDER_PIPELINE="default"
DAEMON_INTERVAL=5

# Parse command-line arguments (Same logic as original)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--daemon) MODE="daemon"; shift ;;
        -b|--batch) MODE="batch"; shift ;;
        --ingest-dir) INGEST_DIR="$2"; shift 2 ;;
        --gpu) USE_GPU="$2"; shift 2 ;;
        --render-pipeline) RENDER_PIPELINE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "  -d, --daemon     Run in mock daemon mode"
            echo "  -b, --batch      Run in mock batch mode"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Mock Processing Functions ---

simulate_step() {
    local step_name=$1
    local duration=$2
    echo "[STEP] Starting: $step_name..."
    sleep "$duration"
    echo "[STEP] Completed: $step_name."
}

process_data() {
    local START_TIMESTAMP=$(date +%s)
    echo ">> Initializing Mock Processing (Mode: $MODE)"
    echo ">> Config: GPU=$USE_GPU, Pipeline=$RENDER_PIPELINE"

    # Create dummy workspace
    mkdir -p "$COLMAP_WORKSPACE"

    # Step 1: Simulated Image Prep
    simulate_step "Image Conversion & Extraction" 2

    # Step 2: Simulated Feature Extraction
    if [[ "$USE_GPU" == "true" ]]; then
        echo ">> [INFO] Using simulated GPU acceleration..."
    fi
    simulate_step "Feature Extraction ($RENDER_PIPELINE)" 3

    # Step 3: Simulated Matching
    simulate_step "Exhaustive Matching" 2

    # Step 4: Simulated Reconstruction
    simulate_step "Sparse Reconstruction" 4

    # Generate Mock Metrics
    generate_metrics "$START_TIMESTAMP"
}

generate_metrics() {
    local start_time=$1
    local end_time=$(date +%s)
    local runtime=$((end_time - start_time))
    
    echo ">> Generating Mock Metrics..."
    cat <<EOF > "$COLMAP_WORKSPACE/metrics.yaml"
mock_results:
  status: "success"
  runtime_seconds: $runtime
  images_processed: 42
  gpu_used: "$USE_GPU"
EOF
    echo ">> Metrics saved to $COLMAP_WORKSPACE/metrics.yaml"
}

# --- Execution Logic ---

if [[ "$MODE" == "daemon" ]]; then
    echo ">> Daemon mode active. Watching $INGEST_DIR every $DAEMON_INTERVAL seconds."
    mkdir -p "$INGEST_DIR"
    
    # Simple loop: If the directory is not empty, "process" it
    while true; do
        if [ -n "$(ls -A "$INGEST_DIR" 2>/dev/null)" ]; then
            echo ">> [DAEMON] New files detected!"
            process_data
            echo ">> [DAEMON] Cleaning up ingest..."
            rm -rf "${INGEST_DIR:?}"/*
        else
            echo ">> [DAEMON] Idle... (Add a file to $INGEST_DIR to trigger)"
        fi
        sleep "$DAEMON_INTERVAL"
    done
else
    # Batch Mode
    process_data
    echo "--- Mock Pipeline finished at $(date) ---"
fi