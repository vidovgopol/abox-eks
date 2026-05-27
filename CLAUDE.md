# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Three-layer Terraform infrastructure that provisions an AWS EKS cluster and runs AI agents on it. Agents/MCP servers are **not** applied by Terraform — they are reconciled onto the cluster by **Flux GitOps** from an OCI artifact built out of `releases/`.

```
Layer 1 — eks-bootstrap/   VPC + EKS cluster
Layer 2 — ai-infra/        kagent + agentgateway + AWS LBC + NLB Gateway, plus Qdrant,
                           Agent Registry, MCP Governance, KRO + Agent Sandbox
Layer 3 — flux-install/    Flux operator + OCIRepository + Kustomization
releases/                  Agent/MCPServer CRs — reconciled by Flux, NOT Terraform
```

> Test/learning environment: local Terraform state (no remote backend, git-ignored), no app-layer auth on the gateway (single-IP AWS SG only).

## Common Commands

### Makefile (run from repo root)

```bash
make eks-bootstrap-up   # terraform init + two-phase apply in eks-bootstrap/
make kubeconfig         # aws eks update-kubeconfig using layer 1 outputs
make ai-infra-up        # CRDs-first apply, then full apply in ai-infra/
make flux-install-up    # Flux operator + OCI sync (passes releases_oci_url)
make up                 # all three layers in order
make down               # destroy flux-install → ai-infra → eks-bootstrap
```

All applies/destroys use `-lock=false` (local state). `make up` does **not** deploy agents — see the GitOps section below.

### Direct Terraform (run from each layer's directory)

```bash
terraform -chdir=<layer> init
terraform -chdir=<layer> plan
terraform -chdir=<layer> apply
terraform -chdir=<layer> destroy
```

### Layer 1 — two-phase apply (first-time only)

```bash
terraform -chdir=eks-bootstrap apply -target=module.vpc -target=module.eks
terraform -chdir=eks-bootstrap apply
```

### Layer 2 — CRDs-first apply (first-time only, or on CRD errors)

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

## GitOps: deploying / changing agents (critical workflow)

Editing files under `releases/` and running `terraform apply` or `kubectl apply` does **nothing** by itself. Agents reach the cluster only through the tag-driven pipeline:

```bash
# 1. edit files under releases/agents/ (and agents/kustomization.yaml if adding a file)
git add releases/ && git commit -m "..."
git tag v0.x.y && git push origin main && git push origin v0.x.y
```

`.github/workflows/flux-push.yaml` (triggers on `v*` tags) packages `releases/` as an OCI artifact, pushes it to `ghcr.io/<org>/abox-eks/releases:<tag>`, and re-tags it `latest`. Flux's `OCIRepository abox-eks-releases` polls `latest` every 5 min; the `Kustomization abox-eks-agents` applies it with `prune = true` (removing a manifest from git deletes it from the cluster). Everything in `releases/agents/` lands in the `kagent` namespace.

To reconcile immediately instead of waiting:

```bash
flux reconcile source oci abox-eks-releases -n flux-system
flux reconcile kustomization abox-eks-agents -n flux-system
# status:
kubectl get ocirepositories,kustomizations -n flux-system
kubectl get agents,mcpservers -n kagent
```

## Architecture

### Layer 1 — eks-bootstrap

- VPC CIDR `10.241.0.0/16`, region `eu-central-1` (var), 3 private + 3 public subnets, single NAT gateway.
- Cluster `aire-eks` (fixed, no random suffix), Kubernetes 1.34, AL2023, `t3.medium` managed node group (min 2 / max 3 / desired 2).
- `maxPods` raised to 48 via `cloudinit_pre_nodeadm` NodeConfig (matches VPC CNI prefix delegation).
- Node SG has a self-referential `ingress_self_all` rule so cross-node pod traffic on well-known ports (e.g. 80) works.
- Addons: coredns, eks-pod-identity-agent (`before_compute`), kube-proxy, vpc-cni (`before_compute`, `enableNetworkPolicy = "true"`), aws-ebs-csi-driver.
- Public API endpoint restricted to `var.eks_public_access_cidrs` (required).
- Creates AWS SG `agentgw-lb-aire-eks`: inbound port 80 from `var.allowed_cidr` only. Created here but **consumed in Layer 2** (looked up by name and attached to the Gateway NLB).

### Layer 2 — ai-infra

The heaviest layer. Resolves cluster creds via `data.aws_eks_cluster` / `aws_eks_cluster_auth` (no remote state). Two install mechanisms coexist: the **Helm/kubectl Terraform providers** for first-class resources, and **`null_resource` + `local-exec`** (running `helm`/`kubectl`/`curl` on the operator's machine) for charts/manifests that don't fit the providers cleanly. The `local-exec` ones require `helm`, `kubectl`, `curl`, and `tar` available locally.

- **AWS Load Balancer Controller** (`kube-system`): IAM policy pulled from the upstream `iam_policy.json`, EKS Pod Identity association, Helm release. LBC provisions the Gateway's NLB (`aws-load-balancer-type=external`, `nlb-target-type=ip`) and, via `manage-backend-security-group-rules=true`, manages node-SG ingress automatically — so **no manual `aws_security_group_rule` is needed**. The NLB reuses the `agentgw-lb-*` SG from Layer 1 via the `aws-load-balancer-security-groups` annotation.
- **gp3 StorageClass** set as cluster default (EBS CSI, `WaitForFirstConsumer`).
- **kagent** (`kagent` ns): Helm `kagent-crds` + `kagent`. Configured via the chart's `providers` block (default `anthropic`, model `claude-sonnet-4-6`, `apiKeySecretRef = anthropic-api-key`); all bundled sub-agents (istio, promql, helm, cilium, grafana-mcp, etc.) disabled. `ModelConfig default-model-config` is **created by the chart, not Terraform** (v1alpha2 schema: `spec.apiKeySecret` / `spec.apiKeySecretKey`).
- **Standard Gateway API CRDs** (`gateway.networking.k8s.io`) applied via `null_resource` from `gateway-api v1.2.1 standard-install.yaml` — the agentgateway chart only ships its own kgateway CRDs.
- **agentgateway** (`agentgateway-system` ns) + `Gateway agentgateway-external` + `HTTPRoute kagent`: `/api` → `kagent-controller:8083`, `/` → `kagent-ui:8080`. (`agent-gw-config.yaml` is a standalone reference copy with different backends and is **not** applied by Terraform — the live route is inline in `main.tf`.)
- **`anthropic-api-key` Secret** in `kagent` (from `var.anthropic_api_key`).
- **Qdrant** (`qdrant` ns): Helm release with gp3 PVC, auth via `qdrant-api-key` Secret (`var.qdrant_api_key`).
- **Agent Registry** (`agentregistry` ns): Helm install via `null_resource` from `den-vasyliev/agentregistry-inventory`, plus a `DiscoveryConfig` CR scoped to read `Agent`/`MCPServer`/`ModelConfig` in `kagent`. Destroy provisioner strips `agentcatalog` finalizers first to avoid a stuck `Terminating` namespace.
- **MCP Security Governance** (`mcp-governance` ns): Helm install via `null_resource` from `techwithhuz/mcp-security-governance` using custom images `vidovgopol/mcp-governance-{controller,dashboard}`, plus `mcp-governance-policy.yaml` (`MCPGovernancePolicy` + `GovernanceEvaluation`). Optional `google-api-key` Secret enables AI (Gemini) scoring when `var.google_api_key` is set.
- **KRO** (`kro-system`) installed via `null_resource` helm (OCI tag mismatch makes the helm provider unusable), + `ResourceGraphDefinition agentic-sandbox` (`agentic-sandbox-rgd.yaml`) which generates the `AgenticSandbox` CRD (`custom.agents.x-k8s.io/v1alpha1`) composing Sandbox + Service + NetworkPolicy + Ingress.
- **Agent Sandbox** (`agent-sandbox-system`): controller + CRDs from upstream release manifest `v0.4.6` via `null_resource`. CRD: `sandboxes.agents.x-k8s.io`.
- Demo `AgenticSandbox` in `default` ns (`agentic-sandbox-demo.yaml`), gated by `var.agentic_sandbox_demo_enabled` (default `true`; set `false` in production).

### Layer 3 — flux-install

- Helm `flux-operator` + `flux-instance` (`flux-system`, distribution `=2.x`).
- `OCIRepository abox-eks-releases` → `var.releases_oci_url` tag `latest`, interval 5m.
- `Kustomization abox-eks-agents` applies path `./` from that source with `prune = true`.

### Cross-layer dependencies

No `terraform_remote_state`. The only shared value is the cluster name (`aire-eks`); Layers 2 and 3 each re-query AWS:

```hcl
data "aws_eks_cluster"      { name = var.cluster_name }
data "aws_eks_cluster_auth" { name = var.cluster_name }
```

`kubectl_manifest` resources use the `gavinbunney/kubectl` provider (not a HashiCorp one).

## Variables

| Variable | Layer | Required | Default | Pass via |
|---|---|---|---|---|
| `region` | 1,2,3 | no | `eu-central-1` | — |
| `eks_public_access_cidrs` | 1 | **yes** | — | `TF_VAR_eks_public_access_cidrs='["1.2.3.4/32"]'` |
| `allowed_cidr` | 1 | **yes** | — | `TF_VAR_allowed_cidr=1.2.3.4/32` (agentgw NLB inbound) |
| `cluster_name` | 2,3 | no | `aire-eks` | — |
| `anthropic_api_key` | 2 | **yes** | — | `TF_VAR_anthropic_api_key=sk-ant-...` |
| `qdrant_api_key` | 2 | **yes** | — | `TF_VAR_qdrant_api_key=...` |
| `google_api_key` | 2 | no | `""` (AI scoring off) | `TF_VAR_google_api_key=...` |
| `kagent_version` | 2 | no | `0.9.2` | — |
| `agentgateway_version` | 2 | no | `v2.2.1` | — |
| `aws_lbc_chart_version` | 2 | no | `1.11.0` | — |
| `qdrant_chart_version` | 2 | no | `1.18.0` | — |
| `kro_version` | 2 | no | `0.9.2` | — |
| `agent_sandbox_version` | 2 | no | `v0.4.6` | — |
| `agentic_sandbox_demo_enabled` | 2 | no | `true` | — |
| `releases_oci_url` | 3 | **yes** | — | `TF_VAR_releases_oci_url=oci://ghcr.io/<org>/abox-eks/releases` |

## Helm / external chart sources

| Source | Repository | Install path |
|---|---|---|
| kagent-crds / kagent | `oci://ghcr.io/kagent-dev/kagent/helm` | helm provider |
| agentgateway-crds / agentgateway | `oci://ghcr.io/kgateway-dev/charts` | helm provider |
| aws-load-balancer-controller | `https://aws.github.io/eks-charts` | helm provider |
| qdrant | `https://qdrant.github.io/qdrant-helm` | helm provider |
| flux-operator / flux-instance | `oci://ghcr.io/controlplaneio-fluxcd/charts` | helm provider (layer 3) |
| kro | `oci://registry.k8s.io/kro/charts/kro` | `null_resource` helm |
| agentregistry | `den-vasyliev/agentregistry-inventory` (tarball) | `null_resource` helm |
| mcp-governance | `techwithhuz/mcp-security-governance` (tarball) | `null_resource` helm |
| agent-sandbox | `kubernetes-sigs/agent-sandbox` release manifest | `null_resource` kubectl |
| gateway-api CRDs | `kubernetes-sigs/gateway-api` v1.2.1 | `null_resource` kubectl |

## Important: cluster name change warning

The original `eks-bootstrap` used a random suffix (`aire-eks-<random>`); it is now fixed at `aire-eks`. If an old-named cluster is still in state, applying Layer 1 will **destroy and recreate** the cluster.
