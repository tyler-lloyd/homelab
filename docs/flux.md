# GitOps (Flux)

Workloads are deployed by [Flux](https://fluxcd.io) from this repo's `main` branch.
`make flux` installs it once. After that, Flux pulls
`http://192.168.1.235:3001/tyler/homelab.git` every minute and applies
`k8s/clusters/homelab/`, including its own manifests in `flux-system/`.

Everything Flux reads is under `k8s/`:

```
clusters/homelab/
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
Both use `k8s/infrastructure/controllers/cilium/values.yaml`, so Flux's first
reconcile doesn't change the CNI. Change Cilium by committing to that file or to
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
