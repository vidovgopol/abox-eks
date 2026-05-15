# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Three-layer Terraform infrastructure that provisions an AWS EKS cluster and deploys AI agents onto it.

```
Layer 1 — eks-bootstrap/   VPC + EKS cluster
Layer 2 — ai-infra/        kagent + agentgateway Helm releases, Anthropic Secret, ModelConfig, Gateway
Layer 3 — ai-agents/       kagent Agent CR (KubeAssist — k8s operations)
```

## Common Commands

### Makefile (run from repo root)

```bash
make eks-bootstrap-up   # terraform init + apply in eks-bootstrap/
make kubeconfig         # aws eks update-kubeconfig using layer 1 outputs
make ai-infra-up        # terraform init + apply in ai-infra/
make ai-agents-up       # terraform init + apply in ai-agents/
make up                 # all three layers in order
make down               # destroy layer3 → layer2 → layer1
```

### Direct Terraform (run from each layer's directory)

```bash
terraform init
terraform plan
terraform apply
terraform destroy
```

### Layer 1 — two-phase apply (first-time only)

```bash
terraform -chdir=eks-bootstrap apply -target=module.vpc -target=module.eks
terraform -chdir=eks-bootstrap apply
```

### Layer 2 — two-phase apply (first-time only, if CRD errors occur)

```bash
terraform -chdir=ai-infra apply \
  -target=helm_release.kagent_crds \
  -target=helm_release.agentgateway_crds
terraform -chdir=ai-infra apply
```

### Configure kubectl after layer 1

```bash
aws eks update-kubeconfig \
  --region $(terraform -chdir=eks-bootstrap output -raw region) \
  --name $(terraform -chdir=eks-bootstrap output -raw cluster_name)
```

## Architecture

### Layer 1 — eks-bootstrap

- VPC CIDR `10.241.0.0/16`, region `eu-central-1` (variable), 3 private + 3 public subnets, single NAT gateway
- Cluster name: `aire-eks` (stable, no random suffix)
- Kubernetes 1.34, AL2023 AMI, `t3.large` × 2
- Public API endpoint restricted to `46.219.224.0/21`
- Addons: coredns, eks-pod-identity-agent, kube-proxy, vpc-cni

### Layer 2 — ai-infra

- Helm charts (OCI): `kagent-crds`, `kagent`, `agentgateway-crds`, `agentgateway`
- AWS Security Group `agentgw-lb-aire-eks`: port 80 inbound from `var.allowed_cidr` only; attached to the Gateway NLB via annotation `service.beta.kubernetes.io/aws-load-balancer-security-groups`
- `kubernetes_secret_v1` `anthropic-api-key` in namespace `kagent` (value from `var.anthropic_api_key`, sensitive)
- `ModelConfig` CR `default-model-config` (`kagent.dev/v1alpha2`) is created by the kagent Helm chart (v0.9.2+); **not managed by Terraform**. Uses `spec.apiKeySecret` / `spec.apiKeySecretKey` fields (v1alpha2 schema — not `spec.anthropic.apiKeySecretRef`).
- `Gateway` + `HTTPRoute`: routes `/api` → `kagent-controller:8083`, `/` → `kagent-ui:8080`

### Layer 3 — ai-agents

- Applies `ai-agents/agent.yaml` via `kubectl_manifest`
- `Agent` CR `kubagent` (kind `kagent.dev/v1alpha2`): KubeAssist agent with 18 k8s MCP tools, references `default-model-config`

### Cross-layer dependencies

Layers 2 and 3 resolve the cluster credentials by querying AWS directly:
```hcl
data "aws_eks_cluster"      { name = var.cluster_name }
data "aws_eks_cluster_auth" { name = var.cluster_name }
```
No `terraform_remote_state` — the cluster name (`aire-eks`) is the only shared value.

## Sensitive variables (layer 2)

| Variable | How to pass |
|---|---|
| `anthropic_api_key` | `export TF_VAR_anthropic_api_key=sk-ant-...` |
| `allowed_cidr` | `export TF_VAR_allowed_cidr=x.x.x.x/32` |

## Helm chart OCI URLs

| Chart | Repository |
|---|---|
| kagent-crds / kagent | `oci://ghcr.io/kagent-dev/kagent/helm` |
| agentgateway-crds / agentgateway | `oci://ghcr.io/kgateway-dev/charts` |

## Important: cluster name change warning

The original `eks-bootstrap` used a random suffix (`aire-eks-<random>`). It is now `aire-eks` (fixed).
If an existing cluster with the old name is in state, `terraform apply` on layer 1 will **destroy and recreate** the cluster.
