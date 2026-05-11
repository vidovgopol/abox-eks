# abox-eks

> **⚠ TEST / LEARNING ENVIRONMENT — NOT PRODUCTION READY**
>
> This setup has several intentional shortcuts that must be addressed before any production use:
>
> - **Local Terraform state** — no remote backend (S3 + DynamoDB locking). State files live on your machine and are git-ignored. Losing them means losing track of deployed resources.
> - **No CI/CD** — all applies are run manually from a local console using temporary AWS credentials.
> - **No application-layer authentication on the gateway** — access is restricted to a single IP via an AWS Security Group, but there is no token, mTLS, or OAuth in front of the AI agent API. Anyone who reaches the endpoint can interact with the agents.
>
> Planned improvements before production: remote state, GitHub Actions pipeline, gateway authentication (API key or OIDC), HTTPS with ACM certificate.

AWS EKS cluster with AI agents, provisioned in three independent Terraform layers.

```
Layer 1 — eks-bootstrap/   VPC + EKS cluster (t3.large × 2, eu-central-1)
Layer 2 — ai-infra/        kagent + agentgateway, Anthropic Secret, ModelConfig, restricted Gateway
Layer 3 — ai-agents/       KubeAssist Agent CR (k8s operations)
```

## Prerequisites

- Terraform >= 1.3
- AWS CLI configured (`aws configure` or environment variables)
- `kubectl`

## Quick start

### 1. Export sensitive variables

```bash
export TF_VAR_eks_public_access_cidrs='["<your-corp-or-home-ip>/32"]'  # curl ifconfig.me
export TF_VAR_anthropic_api_key="sk-ant-..."
export TF_VAR_allowed_cidr="<your-public-ip>/32"
```

### 2. Bootstrap layer by layer

```bash
make eks-bootstrap-up   # ~15 min — VPC + EKS
make kubeconfig         # configure kubectl
make ai-infra-up        # kagent + agentgateway + Secret
make ai-agents-up       # KubeAssist agent
```

Or all at once (sequential, each layer confirms before proceeding):

```bash
make up
```

### 3. Teardown

Always destroy in reverse order to avoid CRD finalizer deadlocks:

```bash
make down           # ai-agents → ai-infra → eks-bootstrap
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

## Variables

| Variable | Layer | Default | Description |
|---|---|---|---|
| `region` | 1, 2, 3 | `eu-central-1` | AWS region |
| `eks_public_access_cidrs` | 1 | — | **Required.** List of CIDRs for EKS API public access, e.g. `["1.2.3.4/32"]` |
| `cluster_name` | 2, 3 | `aire-eks` | EKS cluster name |
| `anthropic_api_key` | 2 | — | **Required.** Pass via `TF_VAR_anthropic_api_key` |
| `allowed_cidr` | 2 | — | **Required.** Your IP (`x.x.x.x/32`) for agentgateway access |
| `kagent_version` | 2 | `0.9.2` | kagent Helm chart version |
| `agentgateway_version` | 2 | `v2.2.1` | agentgateway Helm chart version |

## Security

The agentgateway load balancer is protected by a dedicated AWS Security Group that allows
inbound HTTP (port 80) only from `allowed_cidr`. There is no application-layer authentication —
do not widen this CIDR to `0.0.0.0/0`.

> **Note:** The `allowed_cidr` SG is attached to the NLB with the annotation
> `service.beta.kubernetes.io/aws-load-balancer-security-groups`, which *replaces* the
> auto-generated SG. If you need to add more CIDRs, update the `aws_security_group` resource
> in `ai-infra/main.tf`.

## Helm chart sources

| Chart | OCI URL |
|---|---|
| kagent-crds | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` |
| kagent | `oci://ghcr.io/kagent-dev/kagent/helm/kagent` |
| agentgateway-crds | `oci://ghcr.io/kgateway-dev/charts/agentgateway-crds` |
| agentgateway | `oci://ghcr.io/kgateway-dev/charts/agentgateway` |
