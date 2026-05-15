variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name (output of layer 1)"
  type        = string
  default     = "aire-eks"
}

variable "releases_oci_url" {
  description = "OCI URL for the releases artifact pushed by the GitHub workflow, e.g. oci://ghcr.io/your-org/abox-eks/releases"
  type        = string
}
