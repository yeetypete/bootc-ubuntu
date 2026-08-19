# ubuntu-bootc developer tasks.

# Image repository for the built image.
image := "yeetypete/ubuntu-bootc"
# Version for image labels and tag suffix (docker bake strips a leading "v").
version := "v0.0.0"
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Whether `build` also pushes the image to the registry (set push=true on releases).
push := "false"
# Tag the image is built with.
tag := "26.04"

oci_archive := "image.oci"

# List available recipes.
default:
    @just --list

# Build the bootc container image.
build *args:
    IMAGE={{ image }} VERSION={{ version }} REVISION={{ revision }} PUSH={{ push }} \
        docker buildx bake ubuntu-bootc {{ args }}

# Load the built image into podman storage, which is where bcvk reads from.
load:
    podman pull docker-daemon:{{ image }}:{{ tag }}

# Boot the image as a throwaway VM and open a shell in it. The VM is discarded on exit.
vm: load
    bcvk ephemeral run-ssh docker.io/{{ image }}:{{ tag }}

# Remove the generated OCI archive.
clean:
    rm -rf {{ oci_archive }}
