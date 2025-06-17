#!/bin/bash

# Determine what to run based on environment variables
if [ "$RUN_API" = "true" ]; then
    echo "Starting FastAPI server"
    cd /workspace
    uvicorn api:app --host 0.0.0.0 --port 8000
else
    echo "Starting COLMAP processing"
    exec /workspace/colmap.sh "$@"
fi