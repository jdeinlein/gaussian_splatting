# gaussian splatting dummy workflow for LARA3D demo
from prefect import flow, task


@task
def download_image_data():
    print("Downloading image data...")
    # Simulate downloading data
    return "image_data"


@task
def process_image_data(image_data):
    print(f"Processing {image_data}...")


@task
def upload_results():
    print("Uploading results...")


@flow(log_prints=True)
def gaussian_splat_workflow():
    print("Running Gaussian Splatting Workflow")
    image_data = download_image_data()
    process_image_data(image_data)
    upload_results()
