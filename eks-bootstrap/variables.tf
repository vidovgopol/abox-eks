variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API server public endpoint — pass your corporate/home IP, e.g. [\"1.2.3.4/32\"]"
  type        = list(string)
}

variable "allowed_cidr" {
  description = "Your IP in CIDR notation (e.g. 1.2.3.4/32) — the agentgateway LB will accept traffic only from this address"
  type        = string
}