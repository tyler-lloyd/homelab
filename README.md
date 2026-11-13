# homelab

Everything needed to build my homelab's Kubernetes cluster from nothing: three
control plane VMs and a worker running [Flatcar](https://www.flatcar.org) on two
Proxmox VE hosts, and everything that runs on them, deployed by [Flux](https://fluxcd.io).
Clone it, put the secrets back, and `make` rebuilds the lot.

| Node        | IP           | Proxmox host | VMID | GPU |
| ----------- | ------------ | ------------ | ---- | --- |
| API VIP     | 192.168.1.20 | (keepalived) |      |     |
| k8s-cp1     | 192.168.1.21 | 192.168.1.10 | 121  |     |
| k8s-cp2     | 192.168.1.22 | 192.168.1.10 | 122  |     |
| k8s-cp3     | 192.168.1.23 | 192.168.1.10 | 123  |     |
| k8s-worker1 | 192.168.1.24 | 192.168.1.11 | 124  | RTX A400 ([GPU nodes](docs/gpu.md)) |

Stack: Flatcar stable, Kubernetes v1.37.1 + CRI-O v1.37.2, keepalived and HAProxy
(all as [sysext bakery](https://extensions.flatcar.org) extensions), Cilium 1.20.2
replacing kube-proxy. The API is served at `https://192.168.1.20:6444` (HAProxy on
every control plane node → kube-apiserver `:6443` on each). Pods use 100.100.0.0/16,
services 172.16.0.0/16. LoadBalancer Services get 192.168.1.31–.40.

## Layout

```
Makefile, nodes.conf    entry point; the nodes, their IPs and Proxmox hosts
butane/                 the nodes: Flatcar config layers, with no addresses in them
scripts/                VM lifecycle on Proxmox, per-node config and CA generation
k8s/                    the workloads: everything Flux applies
  clusters/homelab/       Flux itself, what it syncs in which order, and
                          cluster.env: every address the nodes and workloads use
  infrastructure/         controllers (Cilium, Proxmox CSI, zora), then their configs
  apps/                   Pi-hole
  manifests/              applied by hand: NVIDIA device plugin (make gpu-plugin)
docs/                   how each part works and how to operate it
.sops.yaml              which key the *.sops.yaml secrets are encrypted to

secrets/                git-ignored: age key, cluster CAs + join token, kubeconfig
ign/                    git-ignored: compiled Ignition configs (secrets baked in)
```

| Doc | Covers |
| --- | ------ |
| [docs/nodes.md](docs/nodes.md) | How nodes are built and bootstrap; adding and rebuilding them |
| [docs/flux.md](docs/flux.md) | GitOps layout, SOPS secrets, Cilium handover, upgrading Flux |
| [docs/networking.md](docs/networking.md) | LoadBalancer IPs, per-pod WireGuard tunnels (zora) |
| [docs/storage.md](docs/storage.md) | PVCs as Proxmox disks |
| [docs/gpu.md](docs/gpu.md) | GPU passthrough, host prep, using the GPU from a pod |
| [docs/pihole.md](docs/pihole.md) | LAN DNS |

## Building it

Needs `butane`, `kubectl`, `sops` and `age` locally, and root SSH to both Proxmox
hosts. On each host, the `local` storage must allow snippets:
`pvesm set local --content <existing types>,snippets`.

```sh
# 1. Secrets: restore secrets/ from backup. Only for a brand-new cluster:
make secrets      # CAs + join token -> secrets/00_base-k8s-{token,pki}.yaml

# 2. Nodes
make              # build ign/*.ign
make image        # fetch + GPG-verify the Flatcar Proxmox image on both hosts
make up           # create + start all VMs; the cluster bootstraps itself
make kubeconfig   # then: KUBECONFIG=secrets/kubeconfig kubectl get nodes

# 3. Workloads
make flux         # install Flux; it deploys everything under k8s/ from git
make gpu-plugin   # NVIDIA device plugin, once the GPU node has joined
```

`make status` shows the VMs. `make up-<node>` / `make down-<node>` act on single
nodes, and `make down` destroys every VM.

Not rebuilt from this repo:

- **The Proxmox hosts** themselves, and the GPU host prep in [docs/gpu.md](docs/gpu.md).
- **The git server.** Flux pulls `main` from the Gitea at `192.168.1.235:3001`
  (`k8s/clusters/homelab/flux-system/gotk-sync.yaml`), which runs outside the cluster
  and has to be up with this repo on it.
- **Data on volumes**, such as Pi-hole's blocklists and query history. The Proxmox
  disks outlive a rebuilt VM, but a brand-new cluster gets new, empty volumes.
- **Router settings:** DHCP hands out 192.168.1.31 as DNS and keeps .31–.40 out of
  its pool.

## Secrets

**Nothing secret is committed unencrypted.** There are two kinds:

- **In git, encrypted:** Kubernetes Secrets as `*.sops.yaml`, encrypted with
  [SOPS](https://getsops.io) to the age public key in `.sops.yaml`. See
  [docs/flux.md](docs/flux.md#secrets).
- **Not in git:** everything in `secrets/`.

| File in `secrets/` | What it is | If lost |
| ------------------ | ---------- | ------- |
| `age.agekey` | Private key for every `*.sops.yaml` in git | Those secrets can't be decrypted: recreate each one and re-encrypt to a new key |
| `00_base-k8s-token.yaml`, `00_base-k8s-pki.yaml`, `certs/` | The cluster's CAs, service-account key and join token | Nodes can't be added or rebuilt; `make secrets` starts a new cluster |
| `kubeconfig` | Admin access to the cluster | `make kubeconfig` fetches it again |

**Back up `secrets/` somewhere outside this machine and the cluster.** `make` never
generates these implicitly, so a build without them stops rather than quietly making a
different cluster.

The repo does say how the LAN is laid out (private addresses, hostnames, the SSH
public key in `butane/10_base-ha.yaml`). None of that is a credential.

## Using it for your own lab

It's my lab's config, not a template, but most of it carries over. You'd change the
addresses (all of them are in `nodes.conf` and `k8s/clusters/homelab/cluster.env`), the
Proxmox CSI config (`docs/storage.md`), the SSH key in
`butane/10_base-ha.yaml` and the Flux repo URL in `gotk-sync.yaml`, and replace the
`*.sops.yaml` files with your own, encrypted to your own key (`make age-key`, then put
its public key in `.sops.yaml`).

## License

[MIT](LICENSE). `k8s/manifests/nvidia-device-plugin.yaml` is NVIDIA's, under the
Apache License 2.0 as its header says.
