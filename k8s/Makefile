# Flatcar HA Kubernetes on Proxmox VE.
#   make secrets   generate the cluster CAs + join token (once per cluster)
#   make           build every node's Ignition config into ign/
#   make image     download + verify the Flatcar Proxmox image on each Proxmox host
#   make up        create and start all VMs (or up-<node> for one)
#   make down      destroy all VMs (or down-<node> for one)
#   make status    show VM state on the Proxmox hosts
#   make kubeconfig  fetch the admin kubeconfig into ./kubeconfig
#   make gpu-plugin  install the NVIDIA device plugin (for nodes with a gpu in nodes.conf)

BUTANE ?= butane

NODES     := $(shell awk '!/^[#]/ && NF { print $$1 }' nodes.conf)
PVE_HOSTS := $(shell awk '!/^[#]/ && NF { print $$3 }' nodes.conf | sort -u)
FIRST_CP  := $(shell awk '!/^[#]/ && NF { print $$4; exit }' nodes.conf)

SECRETS  := butane/00_base-k8s-token.yaml butane/00_base-k8s-pki.yaml
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

clean:
	rm -rf ign

.PHONY: all secrets image up down status kubeconfig gpu-plugin clean
.PRECIOUS: ign/%.ign
