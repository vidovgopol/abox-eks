# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "aire-eks"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "aire-eks-vpc"

  cidr = "10.241.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.241.1.0/24", "10.241.2.0/24", "10.241.3.0/24"]
  public_subnets  = ["10.241.4.0/24", "10.241.5.0/24", "10.241.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = "1.34"

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
    }
    aws-ebs-csi-driver     = {}
  }

  # Optional
  endpoint_public_access = true
  endpoint_private_access = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Self-referential rule so pods on different nodes can reach each other.
  # Without this, only ephemeral ports (1025-65535) are allowed between nodes;
  # port 80 and other well-known ports are blocked.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    aire-eks-node-group = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]

      min_size     = 2
      max_size     = 2
      desired_size = 2

      # Instance metadata options
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      iam_role_additional_policies = {
        ebs_csi = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
      }
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# ── Security ──────────────────────────────────────────────────────────────────

resource "aws_security_group" "agentgw_lb" {
  name        = "agentgw-lb-${module.eks.cluster_name}"
  description = "Agentgateway ALB - inbound restricted to allowed_cidr"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "HTTP from allowed CIDR only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "agentgw-lb-${module.eks.cluster_name}"
    Terraform = "true"
  }
}