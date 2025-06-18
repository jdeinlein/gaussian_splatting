## API

## Table of Contents
- [Overview](#overview)
- [API Endpoints](#api-endpoints)
  - [File Upload](#file-upload)
  - [Process Uploaded Files](#process-uploaded-files)
  - [Process Existing Files](#process-existing-files)
  - [Check Job Status](#check-job-status)
  - [List All Jobs](#list-all-jobs)
- [Request/Response Examples](#requestresponse-examples)
- [Error Handling](#error-handling)
- [Setup Instructions](#setup-instructions)
- [Usage Examples](#usage-examples)

## Overview

The COLMAP Processing API provides RESTful endpoints for 3D reconstruction tasks. It supports:
- Direct file uploads
- Processing of pre-uploaded files
- GPU-accelerated processing
- Multiple quality presets

Base URL: `http://<host>:8000`

## API Endpoints

### File Upload

`POST /upload`

Upload files to the processing queue without immediately starting processing.

**Parameters**:
- `files` (required): One or more image files

**Response**:
```json
{
  "job_id": "string",
  "message": "string",
  "upload_path": "string"
}