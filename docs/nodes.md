# Nodes (Flatcar on Proxmox)

Adapted from Flatcar's [High Availability Kubernetes](https://www.flatcar.org/docs/latest/orchestrate/kubernetes/high-availability-kubernetes/)
guide (libvirt) for two Proxmox VE hosts: control plane on one, workers on the other.

## How a node is built

`nodes.conf` says where each VM goes (Proxmox host, VMID, IP, size, GPU). Each node's
OS config is `butane/<node>.yaml`, which merges numbered layers:

```
00_base-k8s            CRI-O + Kubernetes sysexts              (every node)
00_base-k8s-token      join token + CA hash, from secrets/     (every node)
00_base-k8s-pki        CA and service-account keys, secrets/   (control plane)
10_base-ha             SSH key, cluster-wide settings (versions, VIP, CIDRs)
20_base-ha-cp          keepalived, HAProxy, Cilium CLI         (control plane)
30_base-ha-init        kubeadm init + day-0 Cilium install     (k8s-cp1)
31_base-ha-join-cp     kubeadm join --control-plane            (k8s-cp2, k8s-cp3)
32_base-ha-join        kubeadm join                            (workers)
40_gpu-nvidia          NVIDIA driver + container runtime       (GPU nodes, see gpu.md)
```

`make` compiles them with `butane` into `ign/<node>.ign`, and `make up-<node>` uploads
that to the node's Proxmox host as a snippet and creates the VM from the Flatcar image
(`scripts/pve.sh`). Storage/bridge/gateway defaults live at the top of `scripts/pve.sh`
and can be overridden by env (e.g. `STORAGE=local-zfs make up`).

Bootstrap order happens on its own: cp1 runs `kubeadm init` and installs Cilium,
cp2 joins once cp1's API is ready, cp3 once cp2's is, and workers once the VIP
answers. Progress: `ssh core@192.168.1.21 journalctl -fu kubeadm -u cilium-install`.

## Adding or rebuilding a node

- **Add a worker:** .25–.30 are free. Copy `butane/k8s-worker1.yaml` (dropping the GPU
  bits, keeping the topology labels, see [storage.md](storage.md)), add a line to
  `nodes.conf`, then `make up-<node>`.
- **Rebuild a node:** `make down-<node> up-<node>`. Rebuilding a *control plane* node
  also needs its old etcd member removed first (see below).
- **Upgrade Kubernetes/CRI-O:** the versions and sysext hashes are in
  `butane/00_base-k8s.yaml`, and `K8S_VERSION` in `butane/10_base-ha.yaml` must match.

## Changes from the upstream guide

- VMs are created with `qm` and get Ignition via a cloud-init snippet (`--cicustom user=`).
- keepalived/HAProxy run from sysexts instead of podman Quadlet containers
  (`osixia/keepalived` is unmaintained). keepalived uses unicast VRRP, and HAProxy binds
  `:6444` on every CP node, so it doesn't depend on who holds the VIP.
- The doc's undefined `K8S_CERT_KEY` / `--upload-certs` are gone: the shared CAs are
  pre-provisioned on CP nodes, so they can join (or be rebuilt) at any time. Workers only
  get the join token, not the CA keys.
- The join token never expires (`--token-ttl 0`), so any node can be rebuilt with
  `make down-<node> up-<node>`. Rebuilding a *control plane* node also needs its old etcd
  member removed first (`kubectl -n kube-system exec etcd-k8s-cp1 -- etcdctl ... member remove`).
- Joins wait for a ready API (`/readyz`) rather than an open port.

The CAs and join token are generated once by `make secrets` into `secrets/`
(git-ignored), as two more Butane layers: `00_base-k8s-token.yaml` for every node and
`00_base-k8s-pki.yaml` for control plane nodes only. New secrets mean a new cluster
(`FORCE=1 make secrets`).
