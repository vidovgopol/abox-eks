locals {
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

# ── Security ──────────────────────────────────────────────────────────────────

resource "aws_security_group" "agentgw_lb" {
  name        = "agentgw-lb-${var.cluster_name}"
  description = "Agentgateway load balancer - inbound restricted to allowed_cidr"
  vpc_id      = local.vpc_id

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
    Name      = "agentgw-lb-${var.cluster_name}"
    Terraform = "true"
  }
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

# ── Anthropic secret + ModelConfig ───────────────────────────────────────────

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
  depends_on = [helm_release.kagent]
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
# The SG annotation replaces the auto-created LB security group, so all
# internet traffic on port 80 is filtered to allowed_cidr before reaching pods.

resource "kubectl_manifest" "agentgw_gateway" {
  server_side_apply = true
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "agentgateway-external"
      namespace = "agentgateway-system"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-security-groups" = aws_security_group.agentgw_lb.id
      }
    }
    spec = {
      gatewayClassName = "agentgateway"
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
  depends_on = [helm_release.agentgateway, null_resource.gateway_api_crds]
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
          matches = [{ path = { type = "PathPrefix", value = "/api" } }]
          backendRefs = [{ name = "kagent-controller", port = 8083 }]
        },
        {
          matches = [{ path = { type = "PathPrefix", value = "/" } }]
          backendRefs = [{ name = "kagent-ui", port = 8080 }]
        }
      ]
    }
  })
  depends_on = [kubectl_manifest.agentgw_gateway, helm_release.kagent]
}
