# Usage

## Supported File Formats

The container supports both image and video files as inputs. For image files, the supported formats are *.jpg, *.png, *.heic and *.gif. For video files, the supported container format is *.mp4.

Please be aware that reconstruction is very compute intensive and will take considerable time to finish processing.

For further support you can adjust the configuration in the colmaph.sh file to include more file types supported by [ffmpeg](https://ffmpeg.org/ffmpeg.html#Options) and [imagemagick](https://imagemagick.org/script/formats.php).

## General Usage

To use the container, you need to add your image set to the `ingest`directory and run the docker compose command. If you want to extract the colmap results, you can mount a volume for the output with docker/podman using the `run`command with the `-v`option.

Example:
````
podman run --gpus=all -v COLMAP:/workspace/colmap_workspace docker.io/judein/splatting_container_brush
````