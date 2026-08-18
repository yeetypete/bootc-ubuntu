# ubuntu-bootc developer tasks.

# Image repository for the built image.
image := "yeetypete/ubuntu-bootc"
# Version for image labels and tag suffix (docker bake strips a leading "v").
version := "v0.0.0"
# Git commit SHA for image labels.
revision := `git rev-parse HEAD 2>/dev/null || echo ""`
# Whether `build` also pushes the image to the registry (set push=true on releases).
push := "false"

oci_archive := "image.oci"

# List available recipes.
default:
    @just --list

# Build the bootc container image.
build *args:
    IMAGE={{ image }} VERSION={{ version }} REVISION={{ revision }} PUSH={{ push }} \
        docker buildx bake ubuntu-bootc {{ args }}

# Remove the generated OCI archive.
clean:
    rm -rf {{ oci_archive }}
