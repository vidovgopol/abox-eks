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
