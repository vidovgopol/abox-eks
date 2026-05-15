locals {
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

# ── Security ──────────────────────────────────────────────────────────────────

resource "aws_security_group" "agentgw_lb" {
  name        = "agentgw-lb-${var.cluster_name}"
  description = "Agentgateway ALB - inbound restricted to allowed_cidr"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTP from allowed CIDR only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "agentgateway admin UI from allowed CIDR only"
    from_port   = 15000
    to_port     = 15000
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
    Name      = "agentgw-lb-${var.cluster_name}"
    Terraform = "true"
  }
}

# Allow ALB to reach pods on the node security group (ports 80 and 15000).
# ALB with target-type=ip sends traffic directly to pod IPs; the node SG
# must permit this from the ALB SG.
# The EKS module v21 names the node SG "<cluster_name>-node".
data "aws_security_group" "eks_node" {
  filter {
    name   = "group-name"
    values = ["${var.cluster_name}-node-*"]
  }
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

resource "aws_security_group_rule" "alb_to_nodes_http" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.agentgw_lb.id
  description              = "ALB to kagent pods (port 80)"
}

resource "aws_security_group_rule" "alb_to_nodes_admin" {
  type                     = "ingress"
  from_port                = 15000
  to_port                  = 15000
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.agentgw_lb.id
  description              = "ALB to agentgateway admin UI (port 15000)"
}

# ── AWS Load Balancer Controller IAM ─────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "http" "aws_lbc_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_lbc" {
  name   = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
  policy = data.http.aws_lbc_policy.response_body
}

resource "aws_iam_role" "aws_lbc" {
  name = "aws-lbc-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_lbc" {
  role       = aws_iam_role.aws_lbc.name
  policy_arn = aws_iam_policy.aws_lbc.arn
}

resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lbc.arn
}

# ── AWS Load Balancer Controller ─────────────────────────────────────────────

resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_lbc_chart_version
  namespace  = "kube-system"

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.region
      vpcId       = local.vpc_id
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.aws_lbc.arn
        }
      }
    })
  ]

  depends_on = [aws_eks_pod_identity_association.aws_lbc]
}

# ── Default StorageClass (gp3 via EBS CSI) ───────────────────────────────────

resource "kubectl_manifest" "gp3_storageclass" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }
    provisioner          = "ebs.csi.aws.com"
    volumeBindingMode    = "WaitForFirstConsumer"
    reclaimPolicy        = "Delete"
    allowVolumeExpansion = true
    parameters = {
      type = "gp3"
    }
  })
}

# ── kagent ────────────────────────────────────────────────────────────────────

resource "helm_release" "kagent_crds" {
  name             = "kagent-crds"
  repository       = "oci://ghcr.io/kagent-dev/kagent/helm"
  chart            = "kagent-crds"
  version          = var.kagent_version
  namespace        = "kagent"
  create_namespace = true
}

resource "helm_release" "kagent" {
  name             = "kagent"
  repository       = "oci://ghcr.io/kagent-dev/kagent/helm"
  chart            = "kagent"
  version          = var.kagent_version
  namespace        = "kagent"
  create_namespace = true
  depends_on       = [helm_release.kagent_crds]

  values = [
    yamlencode({
      providers = {
        default = "anthropic"
        anthropic = {
          provider        = "Anthropic"
          model           = "claude-sonnet-4-6"
          apiKeySecretRef = "anthropic-api-key"
          apiKeySecretKey = "api-key"
        }
      }
    })
  ]
}

# ── agentgateway ─────────────────────────────────────────────────────────────

resource "helm_release" "agentgateway_crds" {
  name             = "agentgateway-crds"
  repository       = "oci://ghcr.io/kgateway-dev/charts"
  chart            = "agentgateway-crds"
  version          = var.agentgateway_version
  namespace        = "agentgateway-system"
  create_namespace = true
}

resource "helm_release" "agentgateway" {
  name             = "agentgateway"
  repository       = "oci://ghcr.io/kgateway-dev/charts"
  chart            = "agentgateway"
  version          = var.agentgateway_version
  namespace        = "agentgateway-system"
  create_namespace = true
  wait             = false
  depends_on       = [helm_release.agentgateway_crds]
}

# ── Anthropic secret ─────────────────────────────────────────────────────────

resource "kubectl_manifest" "anthropic_secret" {
  sensitive_fields = ["stringData.api-key"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "anthropic-api-key"
      namespace = "kagent"
    }
    type = "Opaque"
    stringData = {
      "api-key" = var.anthropic_api_key
    }
  })
  depends_on = [helm_release.kagent_crds]
}

# ── Standard Gateway API CRDs ────────────────────────────────────────────────
# agentgateway-crds only installs kgateway-specific CRDs; the standard
# gateway.networking.k8s.io group must be installed separately first.

resource "null_resource" "gateway_api_crds" {
  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
  }

  triggers = {
    version = "v1.2.1"
  }

  depends_on = [helm_release.agentgateway_crds]
}

# ── Gateway + HTTPRoute ───────────────────────────────────────────────────────
# AWS LBC (installed above) manages NLBs when aws-load-balancer-type=external.
# Unlike the in-tree controller, LBC honours aws-load-balancer-security-groups
# on NLBs, so all inbound traffic is filtered to allowed_cidr at the NLB level.

resource "kubectl_manifest" "agentgw_gateway" {
  server_side_apply = true
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "agentgateway-external"
      namespace = "agentgateway-system"
    }
    spec = {
      gatewayClassName = "agentgateway"
      infrastructure = {
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"             = "external"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-security-groups"  = aws_security_group.agentgw_lb.id
        }
      }
      listeners = [{
        name     = "http"
        port     = 80
        protocol = "HTTP"
        allowedRoutes = {
          namespaces = {
            from = "All"
          }
        }
      }]
    }
  })
  depends_on = [helm_release.aws_lbc, helm_release.agentgateway, null_resource.gateway_api_crds]
}

resource "kubectl_manifest" "kagent_httproute" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "kagent"
      namespace = "kagent"
    }
    spec = {
      parentRefs = [{
        name      = "agentgateway-external"
        namespace = "agentgateway-system"
      }]
      rules = [
        {
          matches     = [{ path = { type = "PathPrefix", value = "/api" } }]
          backendRefs = [{ name = "kagent-controller", port = 8083 }]
        },
        {
          matches     = [{ path = { type = "PathPrefix", value = "/" } }]
          backendRefs = [{ name = "kagent-ui", port = 8080 }]
        }
      ]
    }
  })
  depends_on = [kubectl_manifest.agentgw_gateway, helm_release.kagent]
}

# ── agentgateway admin UI service (ClusterIP, port 15000) ────────────────────
# The agentgateway pod exposes its admin UI on port 15000. The Helm chart does
# not create a Service for this port, so we add one here as a ClusterIP target
# for the ALB (target-type=ip bypasses the Service for routing, but we need
# this Service so the ALB TargetGroup can discover the correct port).

resource "kubectl_manifest" "agentgateway_admin_svc" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "agentgateway-admin"
      namespace = "agentgateway-system"
    }
    spec = {
      type = "ClusterIP"
      selector = {
        "app.kubernetes.io/name"     = "agentgateway"
        "app.kubernetes.io/instance" = "agentgateway"
      }
      ports = [{
        name       = "admin"
        port       = 15000
        targetPort = 15000
        protocol   = "TCP"
      }]
    }
  })
  depends_on = [helm_release.agentgateway]
}

# ── ALB Ingress — agentgateway admin UI (port 15000) ─────────────────────────

resource "kubectl_manifest" "alb_ingress_admin" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "agentgateway-admin"
      namespace = "agentgateway-system"
      annotations = {
        "kubernetes.io/ingress.class"                        = "alb"
        "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"              = "ip"
        "alb.ingress.kubernetes.io/group.name"               = "agentgateway"
        "alb.ingress.kubernetes.io/listen-ports"             = jsonencode([{ HTTP = 15000 }])
        "alb.ingress.kubernetes.io/security-groups"          = aws_security_group.agentgw_lb.id
        "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
      }
    }
    spec = {
      ingressClassName = "alb"
      rules = [{
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "agentgateway-admin"
                port = { number = 15000 }
              }
            }
          }]
        }
      }]
    }
  })
  depends_on = [helm_release.aws_lbc, kubectl_manifest.agentgateway_admin_svc]
}
