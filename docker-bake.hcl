variable "IMAGE" {
  description = "Image repository for the built image."
  default     = "yeetypete/ubuntu-bootc"
}

variable "VERSION" {
  description = "Version tag for the built image."
  default     = "v0.0.0"
}

variable "REVISION" {
  description = "Git commit SHA for image labels."
  default     = ""
}

variable "PUSH" {
  description = "Also push the image to the registry (in addition to the local OCI archive)."
  default     = false
}

group "default" {
  targets = ["ubuntu-bootc"]
}

target "ubuntu-bootc" {
  pull       = true
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  tags = [
    "${IMAGE}:26.04",
    "${IMAGE}:26.04-${trimprefix(VERSION, "v")}",
  ]
  labels = {
    "org.opencontainers.image.version"  = trimprefix(VERSION, "v")
    "org.opencontainers.image.revision" = REVISION
  }
  # On release we emit the registry push and the local OCI archive from the same
  # build so they share a manifest digest.
  output = PUSH ? [
    "type=docker,compression=zstd,oci-mediatypes=true",
    "type=oci,dest=image.oci,compression=zstd",
    "type=registry,compression=zstd,oci-mediatypes=true",
    ] : [
    "type=docker,compression=zstd,oci-mediatypes=true",
    "type=oci,dest=image.oci,compression=zstd",
  ]
  attest = [
    {
      type = "provenance"
      mode = "max"
    },
    {
      type = "sbom"
    }
  ]
}
