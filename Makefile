LAYER1 := eks-bootstrap
LAYER2 := ai-infra
LAYER3 := flux-install

.PHONY: all up down \
        eks-bootstrap-up ai-infra-up flux-install-up \
        eks-bootstrap-down ai-infra-down flux-install-down \
        kubeconfig

## Bootstrap all layers in order (set TF_VAR_* first — see README)
up:
	$(MAKE) eks-bootstrap-up
	$(MAKE) ai-infra-up
	$(MAKE) flux-install-up

## Destroy all layers in safe reverse order
down:
	$(MAKE) flux-install-down
	$(MAKE) ai-infra-down
	$(MAKE) eks-bootstrap-down

# ── Individual layers ─────────────────────────────────────────────────────────

eks-bootstrap-up:
	terraform -chdir=$(LAYER1) init
	terraform -chdir=$(LAYER1) apply -target=module.vpc -target=module.eks -lock=false
	terraform -chdir=$(LAYER1) apply -lock=false

ai-infra-up:
	terraform -chdir=$(LAYER2) init
	terraform -chdir=$(LAYER2) apply -target=helm_release.kagent_crds -target=helm_release.agentgateway_crds
	terraform -chdir=$(LAYER2) apply

flux-install-up:
	terraform -chdir=$(LAYER3) init
	terraform -chdir=$(LAYER3) apply -var="releases_oci_url=$(TF_VAR_releases_oci_url)"

eks-bootstrap-down:
	terraform -chdir=$(LAYER1) destroy -lock=false

ai-infra-down:
	terraform -chdir=$(LAYER2) destroy -lock=false

flux-install-down:
	terraform -chdir=$(LAYER3) destroy -lock=false

# ── Utilities ─────────────────────────────────────────────────────────────────

## Configure kubectl for the cluster
kubeconfig:
	aws eks update-kubeconfig \
		--region $$(terraform -chdir=$(LAYER1) output -raw region) \
		--name $$(terraform -chdir=$(LAYER1) output -raw cluster_name)
