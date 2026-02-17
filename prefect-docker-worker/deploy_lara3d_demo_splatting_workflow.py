# This script deploys the Gaussian Splatting workflow to a Docker-based Prefect worker.
# To run this script, ensure you have the necessary Docker image built and available locally.
# Usage:
#  uv run python deploy_lara3d_demo_splatting_workflow.py   


from prefect.deployments.runner import DockerImage
# from prefect.docker import DockerImage
from prefect_docker_worker.lara3d_splatting_workflow import gaussian_splat_workflow

    
if __name__ == "__main__":
    gaussian_splat_workflow.deploy(
        name="gaussian-splatting-dockerfile-deployment-1",
        work_pool_name="my-docker-pool",
        image=DockerImage(
            name="gaussian-splatting-demo-image",
            tag="lara3d-prefect-deploy",
            dockerfile="Dockerfile"
    ),
    push=False
)