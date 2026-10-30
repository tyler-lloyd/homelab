# Flatcar HA Kubernetes on Proxmox VE.
#   make secrets   generate the cluster CAs + join token (once per cluster)
#   make           build every node's Ignition config into ign/
#   make image     download + verify the Flatcar Proxmox image on each Proxmox host
#   make up        create and start all VMs (or up-<node> for one)
#   make down      destroy all VMs (or down-<node> for one)
#   make status    show VM state on the Proxmox hosts
#   make kubeconfig  fetch the admin kubeconfig into ./kubeconfig
#   make gpu-plugin  install the NVIDIA device plugin (for nodes with a gpu in nodes.conf)
#   make flux      install Flux, which then syncs clusters/homelab from git
#   make age.agekey  generate the SOPS/age key for secrets in git (once, back it up)

BUTANE ?= butane

NODES     := $(shell awk '!/^[#]/ && NF { print $$1 }' nodes.conf)
PVE_HOSTS := $(shell awk '!/^[#]/ && NF { print $$3 }' nodes.conf | sort -u)
FIRST_CP  := $(shell awk '!/^[#]/ && NF { print $$4; exit }' nodes.conf)

SECRETS  := butane/00_base-k8s-token.yaml butane/00_base-k8s-pki.yaml
AGE_KEY  := age.agekey
BASE_IGN := $(patsubst butane/%.yaml,ign/%.ign,$(sort $(wildcard butane/[0-9]*.yaml) $(SECRETS)))
NODE_IGN := $(patsubst %,ign/%.ign,$(NODES))

all: $(NODE_IGN)

secrets: $(SECRETS)

# Never regenerated implicitly: new secrets mean a new cluster
$(SECRETS) &:
	./scripts/generate-k8s-certs.sh

# Butane inlines merged configs at build time, so each layer must be built
# before the layers that merge it.
ign/10_base-ha.ign: ign/00_base-k8s.ign ign/00_base-k8s-token.ign
ign/20_base-ha-cp.ign: ign/10_base-ha.ign ign/00_base-k8s-pki.ign
ign/30_base-ha-init.ign ign/31_base-ha-join-cp.ign: ign/20_base-ha-cp.ign
ign/30_base-ha-init.ign: infrastructure/controllers/cilium/values.yaml
ign/32_base-ha-join.ign: ign/10_base-ha.ign
$(NODE_IGN): $(BASE_IGN)

ign/%.ign: butane/%.yaml
	@mkdir -p ign
	$(BUTANE) --strict --pretty --files-dir . $< > $@.tmp
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
	ssh -o StrictHostKeyChecking=accept-new core@$(FIRST_CP) cat .kube/config > $@.tmp
	chmod 600 $@.tmp
	mv $@.tmp $@

gpu-plugin:
	kubectl --kubeconfig kubeconfig apply -f manifests/nvidia-device-plugin.yaml

# The *.sops.yaml secrets in git are encrypted to this key, so it is only made
# on request: a missing key must be restored from backup, not replaced.
$(AGE_KEY):
	age-keygen -o $@

# Install Flux from clusters/homelab/flux-system; from then on it syncs itself
# and everything else under clusters/homelab from git. The first apply creates
# the CRDs (and namespace) but not the GitRepository/Kustomization that need them.
# Also gives Flux the age key as flux-system/sops-age. Safe to re-run: the
# applies take back fields Flux owns by then, with the same values from git.
flux:
	@test -f $(AGE_KEY) || { echo "$(AGE_KEY) missing: restore it from backup (or 'make $(AGE_KEY)' for a new cluster)" >&2; exit 1; }
	-kubectl --kubeconfig kubeconfig apply --server-side --force-conflicts -k clusters/homelab/flux-system
	kubectl --kubeconfig kubeconfig wait --for=condition=established --timeout=60s \
	  crd -l app.kubernetes.io/part-of=flux
	kubectl --kubeconfig kubeconfig -n flux-system create secret generic sops-age \
	  --from-file=age.agekey=$(AGE_KEY) --dry-run=client -o yaml \
	  | kubectl --kubeconfig kubeconfig apply -f -
	kubectl --kubeconfig kubeconfig apply --server-side --force-conflicts -k clusters/homelab/flux-system

clean:
	rm -rf ign

.PHONY: all secrets image up down status kubeconfig gpu-plugin flux clean
.PRECIOUS: ign/%.ign
