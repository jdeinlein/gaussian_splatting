# api.py
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import subprocess
import os
import shutil
import uuid
from typing import Optional
import logging
import json

app = FastAPI(title="COLMAP Processing API")

# Allow CORS for development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
WORKSPACE_BASE = "/workspace"
INGEST_DIR = os.path.join(WORKSPACE_BASE, "ingest")
COLMAP_WORKSPACE = os.path.join(WORKSPACE_BASE, "colmap_workspace")
NERFSTUDIO_OUTPUT = os.path.join(WORKSPACE_BASE, "nerfstudio_dataset")
PROCESSING_JOBS = {}

# Models
class ProcessingRequest(BaseModel):
    input_path: str  # Path to input directory or file
    config: Optional[dict] = None
    mode: str = "batch"  # or "daemon"
    gpu: str = "auto"  # "true", "false", or "auto"
    render_pipeline: str = "default"  # "fast", "high_quality", "default"
    scale: str = "default"  # "large", "default"

class JobStatus(BaseModel):
    job_id: str
    status: str
    message: Optional[str] = None
    output_path: Optional[str] = None

# Helper Functions
def generate_job_id() -> str:
    return str(uuid.uuid4())

def run_colmap_script(params: dict):
    """Run the colmap.sh script with given parameters"""
    try:
        # Create a temporary config file if config is provided
        config_file = None
        if params.get("config"):
            config_path = os.path.join(COLMAP_WORKSPACE, f"config_{params['job_id']}.json")
            with open(config_path, "w") as f:
                json.dump(params["config"], f)
            config_file = config_path

        # Prepare command
        cmd = [
            "/workspace/colmap.sh",
            "--batch" if params["mode"] == "batch" else "--daemon",
            "--ingest-dir", params["input_path"],
            "--colmap-workspace", os.path.join(COLMAP_WORKSPACE, params["job_id"]),
            "--nerfstudio-output", os.path.join(NERFSTUDIO_OUTPUT, params["job_id"]),
            "--gpu", params["gpu"],
            "--render-pipeline", params["render_pipeline"],
            "--scale", params["scale"]
        ]

        if config_file:
            cmd.extend(["--config", config_file])

        # Run the command
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        # Update job status
        if result.returncode == 0:
            PROCESSING_JOBS[params["job_id"]] = {
                "status": "completed",
                "message": "Processing completed successfully",
                "output_path": os.path.join(NERFSTUDIO_OUTPUT, params["job_id"])
            }
        else:
            PROCESSING_JOBS[params["job_id"]] = {
                "status": "failed",
                "message": result.stderr,
                "output_path": None
            }
    except Exception as e:
        PROCESSING_JOBS[params["job_id"]] = {
            "status": "failed",
            "message": str(e),
            "output_path": None
        }

# API Endpoints

@app.post("/upload")
async def upload_files(files: list[UploadFile] = File(...)):
    """Handle direct file uploads"""
    job_id = generate_job_id()
    upload_dir = os.path.join(INGEST_DIR, job_id)
    os.makedirs(upload_dir, exist_ok=True)
    
    for file in files:
        file_path = os.path.join(upload_dir, file.filename)
        async with aiofiles.open(file_path, 'wb') as f:
            await f.write(await file.read())
    
    return {"job_id": job_id, "message": "Files uploaded successfully"}

@app.post("/process/upload", response_model=JobStatus)
async def process_uploaded_files(
    background_tasks: BackgroundTasks,
    files: list[UploadFile] = File(...),
    config: str = Form(None),
    mode: str = Form("batch"),
    gpu: str = Form("auto"),
    render_pipeline: str = Form("default"),
    scale: str = Form("default")
):
    """Combined upload and process endpoint"""
    job_id = generate_job_id()
    upload_dir = os.path.join(INGEST_DIR, job_id)
    os.makedirs(upload_dir, exist_ok=True)
    
    # Save files
    for file in files:
        file_path = os.path.join(upload_dir, file.filename)
        async with aiofiles.open(file_path, 'wb') as f:
            await f.write(await file.read())
    

@app.post("/process", response_model=JobStatus)
async def start_processing(request: ProcessingRequest, background_tasks: BackgroundTasks):
    """Start a new COLMAP processing job"""
    job_id = generate_job_id()
    
    # Create job directories
    input_dir = os.path.join(INGEST_DIR, job_id)
    os.makedirs(input_dir, exist_ok=True)
    
    # Copy input data to ingest directory
    if os.path.isdir(request.input_path):
        shutil.copytree(request.input_path, input_dir, dirs_exist_ok=True)
    else:
        shutil.copy(request.input_path, input_dir)
    
    # Prepare job parameters
    job_params = {
        "job_id": job_id,
        "input_path": input_dir,
        "config": request.config,
        "mode": request.mode,
        "gpu": request.gpu,
        "render_pipeline": request.render_pipeline,
        "scale": request.scale
    }
    
    # Store initial job status
    PROCESSING_JOBS[job_id] = {
        "status": "queued",
        "message": "Job is queued for processing",
        "output_path": None
    }
    
    # Start processing in background
    background_tasks.add_task(run_colmap_script, job_params)
    
    return {
        "job_id": job_id,
        "status": PROCESSING_JOBS[job_id]["status"],
        "message": PROCESSING_JOBS[job_id]["message"]
    }

@app.get("/status/{job_id}", response_model=JobStatus)
async def get_job_status(job_id: str):
    """Get the status of a processing job"""
    if job_id not in PROCESSING_JOBS:
        raise HTTPException(status_code=404, detail="Job not found")
    
    return {
        "job_id": job_id,
        "status": PROCESSING_JOBS[job_id]["status"],
        "message": PROCESSING_JOBS[job_id]["message"],
        "output_path": PROCESSING_JOBS[job_id]["output_path"]
    }

@app.get("/jobs", response_model=dict)
async def list_jobs():
    """List all processing jobs"""
    return PROCESSING_JOBS

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)