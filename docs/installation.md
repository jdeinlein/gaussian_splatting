# Installation of the Docker image

## Installation

To install the Docker image, you can use the following command:

```bash
cd gaussian_splatting
docker compose pull 
```

## Running the Docker image

Install NVIDIA Container Toolkit to run the Docker image with GPU support. Follow the instructions at [NVIDIA Container Toolkit Installation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
Make sure you have Docker and Docker Compose installed on your system. You can find installation instructions for Docker at [Docker Installation](https://docs.docker.com/get-docker/) and for Docker Compose at [Docker Compose Installation](https://docs.docker.com/compose/install/).
After installing the NVIDIA Container Toolkit, you can run the Docker image with GPU support by using the following command:


To run the Docker image, you can use the following command:

```bash
cd gaussian_splatting
docker compose up
```
