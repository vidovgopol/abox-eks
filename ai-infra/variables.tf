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

variable "anthropic_api_key" {
  description = "Anthropic API key injected into the kagent Secret — never commit, pass via TF_VAR_anthropic_api_key"
  type        = string
  sensitive   = true
}

# Set to null to install latest. Pin to a specific version for reproducibility.
# Check releases: https://github.com/kagent-dev/kagent/releases
variable "kagent_version" {
  description = "kagent Helm chart version (same tag for kagent-crds and kagent charts). null = latest."
  type        = string
  default     = "0.9.2"
}

# Pin to the version provided in the course manifests
variable "agentgateway_version" {
  description = "agentgateway Helm chart version (same tag for crds and controller charts)"
  type        = string
  default     = "v2.2.1"
}

variable "aws_lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.11.0"
}

