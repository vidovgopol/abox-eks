LAYER1 := eks-bootstrap
LAYER2 := ai-infra
LAYER3 := ai-agents

.PHONY: all up down \
        eks-bootstrap-up ai-infra-up ai-agents-up \
        eks-bootstrap-down ai-infra-down ai-agents-down \
        kubeconfig

## Bootstrap all three layers in order (set TF_VAR_* first — see README)
up:
	$(MAKE) eks-bootstrap-up
	$(MAKE) ai-infra-up
	$(MAKE) ai-agents-up

## Destroy all three layers in safe reverse order
down:
	$(MAKE) ai-agents-down
	$(MAKE) ai-infra-down
	$(MAKE) eks-bootstrap-down

# ── Individual layers ─────────────────────────────────────────────────────────

eks-bootstrap-up:
	terraform -chdir=$(LAYER1) init
	terraform -chdir=$(LAYER1) apply -target=module.vpc -target=module.eks
	terraform -chdir=$(LAYER1) apply

ai-infra-up:
	terraform -chdir=$(LAYER2) init
	terraform -chdir=$(LAYER2) apply -target=helm_release.kagent_crds -target=helm_release.agentgateway_crds
	terraform -chdir=$(LAYER2) apply

ai-agents-up:
	terraform -chdir=$(LAYER3) init
	terraform -chdir=$(LAYER3) apply

eks-bootstrap-down:
	terraform -chdir=$(LAYER1) destroy

ai-infra-down:
	terraform -chdir=$(LAYER2) destroy

ai-agents-down:
	terraform -chdir=$(LAYER3) destroy

# ── Utilities ─────────────────────────────────────────────────────────────────

## Configure kubectl for the cluster
kubeconfig:
	aws eks update-kubeconfig \
		--region $$(terraform -chdir=$(LAYER1) output -raw region) \
		--name $$(terraform -chdir=$(LAYER1) output -raw cluster_name)
