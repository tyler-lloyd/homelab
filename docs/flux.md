# GitOps (Flux)

Workloads are deployed by [Flux](https://fluxcd.io) from this repo's `main` branch.
`make flux` installs it once. After that, Flux pulls
`http://192.168.1.235:3001/tyler/homelab.git` every minute and applies
`k8s/clusters/homelab/`, including its own manifests in `flux-system/`.

Everything Flux reads is under `k8s/`:

```
clusters/homelab/
  kustomization.yaml     lists everything in this directory (add new files to it)
  cluster.env            the cluster's addresses (see Addresses below)
  flux-system/           Flux itself (gotk-components.yaml is generated, don't edit)
  infrastructure.yaml    Kustomizations infra-controllers -> infra-configs (waits for it)
  apps.yaml              Kustomization apps (after infra-configs) -> apps/
infrastructure/
  controllers/cilium/       HelmRelease adopting the day-0 Cilium install
  controllers/proxmox-csi/  Proxmox CSI plugin + default StorageClass
  controllers/zora/         zora: per-pod WireGuard tunnels
  configs/cilium/           LoadBalancer IP pool + L2 announcement policy
apps/
  pihole/                   LAN DNS at 192.168.1.31
```

No credentials are involved because the repo is public. That also means that
**nothing secret can be committed unencrypted**. If the repo goes private, give the
`flux-system` GitRepository a `secretRef` with a read-only token.

Flux's controllers tolerate the control-plane taint, so they keep reconciling
while workers are down. Check on them with `flux get all -A` and `flux events -A`.

## Addresses

No manifest names a LAN address or the pod CIDR. They say `${API_VIP}`,
`${LB_RANGE_START}`, `${PIHOLE_IP}` or `${POD_CIDR}`, and Flux fills in the value from
`k8s/clusters/homelab/cluster.env` as it applies them. That is the same file the nodes
are built from (see [nodes.md](nodes.md)), so the two can't disagree.

It works like this: `clusters/homelab/kustomization.yaml` turns `cluster.env` into the
ConfigMap `flux-system/cluster-vars`, and the `infra-controllers`, `infra-configs` and
`apps` Kustomizations each name it under `postBuild.substituteFrom`.

- **Flux substitutes every `${NAME}`** in what those three apply, decrypted Secrets
  included, and a name that isn't in `cluster.env` becomes an empty string. Write a
  literal one as `$${NAME}`, or exempt a whole object with the annotation
  `kustomize.toolkit.fluxcd.io/substitute: disabled`, as the L2 announcement policy does.
- **`kubectl kustomize` shows the placeholders**, not the values: only Flux substitutes.
- **Changing a value** is a commit to `cluster.env`. Flux picks it up on the next
  reconcile of each Kustomization (up to an hour; `flux reconcile ks <name>` for now).
  `API_VIP` and the CIDRs can't be changed on a running cluster this way: the nodes
  were built with them.
- **Not covered:** the git URL in `flux-system/gotk-sync.yaml`, and the Proxmox API URL
  inside `proxmox-csi/config.sops.yaml`.

## Secrets

Secrets are committed as `*.sops.yaml` files encrypted with [SOPS](https://getsops.io)
and [age](https://age-encryption.org). Only `data`/`stringData` is encrypted (see the
repo's `/.sops.yaml`), so names and namespaces stay readable. To encrypt a new
Secret, run `sops -e -i foo.sops.yaml`. To edit one, run `sops foo.sops.yaml`.
Any Flux Kustomization that applies them needs a `decryption:` block like
`infra-controllers` has.

The private key is `secrets/age.agekey`, which is git-ignored. `make age-key` generates
it once, and `make flux` loads it into the cluster as `flux-system/sops-age`. `sops`
doesn't look for it there, so decrypting or editing fails until `SOPS_AGE_KEY_FILE`
points at it: in fish, `set -Ux SOPS_AGE_KEY_FILE ~/src/homelab/secrets/age.agekey`;
in bash/zsh, `export SOPS_AGE_KEY_FILE=~/src/homelab/secrets/age.agekey`. Encrypting
only needs the public key in `/.sops.yaml`. **Back it up somewhere outside this machine and the
cluster.** Without it, nobody can decrypt the secrets in git, and a rebuilt
cluster can't apply them.

## Cilium

Cilium is installed on day 0 by `cilium-install.service` on k8s-cp1. Flux then
adopts that Helm release (`cilium` in `kube-system`) and owns it from then on.
Both use `k8s/infrastructure/controllers/cilium/values.yaml`, and both add the API VIP
from `cluster.env` as `k8sServiceHost`, so Flux's first reconcile doesn't change the CNI. Change Cilium by committing to that file or to
the HelmRelease's chart version. `CILIUM_VERSION` only affects new clusters. The
HelmRelease has pruning disabled, so removing it from git leaves Cilium installed.

## Upgrading Flux

Regenerate the components with the new CLI and commit. Flux
applies the result to itself.

```sh
flux install --export \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  > k8s/clusters/homelab/flux-system/gotk-components.yaml
```
