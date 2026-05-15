# abox-eks

> **⚠ TEST / LEARNING ENVIRONMENT — NOT PRODUCTION READY**
>
> - **Local Terraform state** — no remote backend. State files live on your machine and are git-ignored.
> - **No application-layer authentication on the gateway** — access is restricted to a single IP via an AWS Security Group, but there is no token, mTLS, or OAuth in front of the AI agent API.
>
> Planned improvements before production: remote state, gateway authentication (API key or OIDC), HTTPS with ACM certificate.

AWS EKS cluster with AI agents, provisioned in three independent Terraform layers. Agents and MCP servers are managed by **Flux GitOps** — changes to `releases/` are automatically synced to the cluster without manual Terraform runs.

```
Layer 1 — eks-bootstrap/   VPC + EKS cluster (t3.large × 2, eu-central-1)
Layer 2 — ai-infra/        kagent + agentgateway + AWS LBC + NLB Gateway
Layer 3 — flux-install/    Flux operator + OCIRepository + Kustomization sync
           releases/        Agent & MCPServer CRs — reconciled by Flux (not Terraform)
```

## Prerequisites

- Terraform >= 1.3
- AWS CLI configured (`aws configure` or environment variables)
- `kubectl`
- `flux` CLI (for status checks and manual reconciliation)
- GitHub Container Registry write access (for publishing OCI artifacts)

## Quick start

### 1. Export required variables

```bash
export TF_VAR_eks_public_access_cidrs='["<your-public-ip>/32"]'   # curl ifconfig.me
export TF_VAR_anthropic_api_key="sk-ant-..."
export TF_VAR_releases_oci_url="oci://ghcr.io/<your-org>/abox-eks/releases"
```

### 2. Bootstrap layer by layer

```bash
make eks-bootstrap-up     # ~15 min — VPC + EKS + agentgw LB security group
make kubeconfig           # configure kubectl
make ai-infra-up          # kagent + agentgateway + AWS LBC + NLB Gateway
make flux-install-up      # Flux operator + sync from OCI artifact
```

Or all at once:

```bash
make up
```

### 3. Publish agents via GitOps

Agents are **not** applied by Terraform. They are synced by Flux from an OCI artifact stored in GHCR. To deploy or update agents:

```bash
# Edit files under releases/agents/
git add releases/
git commit -m "Update agents"
git tag v0.x.y
git push origin main && git push origin v0.x.y
```

The GitHub Actions workflow (`.github/workflows/flux-push.yaml`) automatically:
1. Packages the `releases/` directory as an OCI artifact
2. Pushes it to `ghcr.io/<org>/abox-eks/releases:<tag>`
3. Tags it as `latest`

Flux polls every 5 minutes for a new `latest` digest and applies the changes. To trigger reconciliation immediately:

```bash
flux reconcile source oci abox-eks-releases -n flux-system
flux reconcile kustomization abox-eks-agents -n flux-system
```

### 4. Teardown

Always destroy in reverse order to avoid CRD finalizer deadlocks:

```bash
make down    # flux-install → ai-infra → eks-bootstrap
```

## Layer 2 — two-phase apply

On the very first apply of `ai-infra`, CRDs must exist before dependent resources are created.
If you see errors about unknown resource types, run:

```bash
terraform -chdir=ai-infra apply \
  -target=helm_release.kagent_crds \
  -target=helm_release.agentgateway_crds

terraform -chdir=ai-infra apply
```

## GitOps structure

```
releases/
├── kustomization.yaml        # root — includes agents/
└── agents/
    ├── kustomization.yaml    # lists all agent & MCP manifests
    ├── mcp-website-fetcher.yaml
    ├── kubagent.yaml
    ├── agent-k8s-simple.yaml
    └── agent-fetch.yaml
```

All resources in `releases/agents/` are applied to the `kagent` namespace. Adding a new agent is as simple as dropping a YAML file in that directory, updating `agents/kustomization.yaml`, and pushing a new tag.

## Check Flux sync status

```bash
kubectl get ocirepositories,kustomizations -n flux-system
flux get sources oci -n flux-system
flux get kustomizations -n flux-system
kubectl get agents,mcpservers -n kagent
```

## Variables

| Variable | Layer | Default | Description |
|---|---|---|---|
| `region` | 1, 2, 3 | `eu-central-1` | AWS region |
| `eks_public_access_cidrs` | 1 | — | **Required.** CIDRs for EKS API public access, e.g. `["1.2.3.4/32"]` |
| `cluster_name` | 2, 3 | `aire-eks` | EKS cluster name |
| `anthropic_api_key` | 2 | — | **Required.** Pass via `TF_VAR_anthropic_api_key` |
| `kagent_version` | 2 | `0.9.2` | kagent Helm chart version |
| `agentgateway_version` | 2 | `v2.2.1` | agentgateway Helm chart version |
| `aws_lbc_chart_version` | 2 | `1.11.0` | AWS Load Balancer Controller Helm chart version |
| `releases_oci_url` | 3 | — | **Required.** OCI URL for the releases artifact, e.g. `oci://ghcr.io/<org>/abox-eks/releases` |

## Security

The agentgateway NLB is protected by a dedicated AWS Security Group (`agentgw-lb-<cluster>`) created in `eks-bootstrap`. It allows inbound HTTP (port 80) only from `eks_public_access_cidrs`. The Security Group is attached to the NLB via the AWS Load Balancer Controller annotation `aws-load-balancer-security-groups`, which replaces the auto-generated SG.

LBC manages backend node SG rules automatically (`manage-backend-security-group-rules: "true"`), so no manual ingress rules are required.

## Helm chart sources

| Chart | OCI URL |
|---|---|
| kagent-crds / kagent | `oci://ghcr.io/kagent-dev/kagent/helm` |
| agentgateway-crds / agentgateway | `oci://ghcr.io/kgateway-dev/charts` |
| flux-operator / flux-instance | `oci://ghcr.io/controlplaneio-fluxcd/charts` |
| aws-load-balancer-controller | `https://aws.github.io/eks-charts` |
