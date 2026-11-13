# Flatcar HA Kubernetes on Proxmox VE.
#   make secrets   generate the cluster CAs + join token (once per cluster)
#   make           build every node's Ignition config into ign/
#   make image     download + verify the Flatcar Proxmox image on each Proxmox host
#   make up        create and start all VMs (or up-<node> for one)
#   make down      destroy all VMs (or down-<node> for one)
#   make status    show VM state on the Proxmox hosts
#   make kubeconfig  fetch the admin kubeconfig into secrets/kubeconfig
#   make gpu-plugin  install the NVIDIA device plugin (for nodes with a gpu in nodes.conf)
#   make flux      install Flux, which then syncs k8s/clusters/homelab from git
#   make age-key   generate the SOPS/age key for secrets in git (once, back it up)

BUTANE ?= butane

# A failed render must fail the build, not hand butane half a config
SHELL       := bash
.SHELLFLAGS := -o pipefail -c

NODES     := $(shell awk '!/^[#]/ && NF { print $$1 }' nodes.conf)
PVE_HOSTS := $(shell awk '!/^[#]/ && NF { print $$4 }' nodes.conf | sort -u)
FIRST_CP  := $(shell awk '!/^[#]/ && $$2 == "control-plane" { print $$5; exit }' nodes.conf)

# Everything local and secret (git-ignored). Back this directory up.
SECRETS_DIR := secrets
SECRETS     := $(SECRETS_DIR)/00_base-k8s-token.yaml $(SECRETS_DIR)/00_base-k8s-pki.yaml
AGE_KEY     := $(SECRETS_DIR)/age.agekey
KUBECONFIG  := $(SECRETS_DIR)/kubeconfig
KUBECTL     := kubectl --kubeconfig $(KUBECONFIG)
FLUX_DIR    := k8s/clusters/homelab/flux-system

# Every address comes from these two, through scripts/render-butane.sh
CLUSTER_ENV := k8s/clusters/homelab/cluster.env
RENDER      := scripts/render-butane.sh
ADDRESSES   := nodes.conf $(CLUSTER_ENV) $(RENDER)

BASE_IGN := $(patsubst butane/%.yaml,ign/%.ign,$(sort $(wildcard butane/[0-9]*.yaml))) \
            $(patsubst $(SECRETS_DIR)/%.yaml,ign/%.ign,$(SECRETS))
NODE_IGN := $(patsubst %,ign/%.ign,$(NODES))

all: $(NODE_IGN)

secrets:
	./scripts/generate-k8s-certs.sh

# Never generated implicitly: new secrets mean a new cluster, so a build that
# can't find them stops instead of quietly making a different one.
$(SECRETS):
	@echo "$@ is missing: restore $(SECRETS_DIR)/ from backup, or run 'make secrets' for a new cluster" >&2; exit 1

# Butane inlines merged configs at build time, so each layer must be built
# before the layers that merge it.
ign/10_base-ha.ign: ign/00_base-k8s.ign ign/00_base-k8s-token.ign
ign/20_base-ha-cp.ign: ign/10_base-ha.ign ign/00_base-k8s-pki.ign
ign/30_base-ha-init.ign ign/31_base-ha-join-cp.ign: ign/20_base-ha-cp.ign
ign/30_base-ha-init.ign: k8s/infrastructure/controllers/cilium/values.yaml
ign/32_base-ha-join.ign: ign/10_base-ha.ign

# --files-dir is the repo root, so `local:` paths in butane/ are relative to it
TO_IGN = $(BUTANE) --strict --pretty --files-dir . > $@.tmp

# A node has no file in butane/: its config is generated from its line in
# nodes.conf, and merges the layers its role needs.
$(NODE_IGN): ign/%.ign: $(ADDRESSES) $(BASE_IGN)
	@mkdir -p ign
	./$(RENDER) node $* | $(TO_IGN)
	mv $@.tmp $@

ign/%.ign: butane/%.yaml $(ADDRESSES)
	@mkdir -p ign
	./$(RENDER) layer $< | $(TO_IGN)
	mv $@.tmp $@

ign/%.ign: $(SECRETS_DIR)/%.yaml
	@mkdir -p ign
	$(TO_IGN) < $<
	mv $@.tmp $@

image: $(addprefix image-,$(PVE_HOSTS))
image-%:
	./scripts/pve.sh image $*

up: $(addprefix up-,$(NODES))
up-%: ign/%.ign
	./scripts/pve.sh create $*

down: $(addprefix down-,$(NODES))
down-%:
	./scripts/pve.sh destroy $*

status:
	@./scripts/pve.sh status

kubeconfig:
	@mkdir -p -m 0700 $(SECRETS_DIR)
	ssh -o StrictHostKeyChecking=accept-new core@$(FIRST_CP) cat .kube/config > $(KUBECONFIG).tmp
	chmod 600 $(KUBECONFIG).tmp
	mv $(KUBECONFIG).tmp $(KUBECONFIG)

# Not under Flux: applied by hand once a GPU node has joined (docs/gpu.md)
gpu-plugin:
	$(KUBECTL) apply -f k8s/manifests/nvidia-device-plugin.yaml

# The *.sops.yaml secrets in git are encrypted to this key, so it is only made
# on request: a missing key must be restored from backup, not replaced.
age-key: $(AGE_KEY)
$(AGE_KEY):
	@mkdir -p -m 0700 $(SECRETS_DIR)
	age-keygen -o $@

# Install Flux from k8s/clusters/homelab/flux-system; from then on it syncs
# itself and everything else under k8s/clusters/homelab from git. The first
# apply creates the CRDs (and namespace) but not the GitRepository/Kustomization
# that need them. Also gives Flux the age key as flux-system/sops-age. Safe to
# re-run: the applies take back fields Flux owns by then, with the same values
# from git.
flux:
	@test -f $(AGE_KEY) || { echo "$(AGE_KEY) missing: restore it from backup (or 'make age-key' for a new cluster)" >&2; exit 1; }
	-$(KUBECTL) apply --server-side --force-conflicts -k $(FLUX_DIR)
	$(KUBECTL) wait --for=condition=established --timeout=60s \
	  crd -l app.kubernetes.io/part-of=flux
	$(KUBECTL) -n flux-system create secret generic sops-age \
	  --from-file=age.agekey=$(AGE_KEY) --dry-run=client -o yaml \
	  | $(KUBECTL) apply -f -
	$(KUBECTL) apply --server-side --force-conflicts -k $(FLUX_DIR)

clean:
	rm -rf ign

.PHONY: all secrets image up down status kubeconfig gpu-plugin age-key flux clean
.PRECIOUS: ign/%.ign
