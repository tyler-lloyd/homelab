# Nodes (Flatcar on Proxmox)

Adapted from Flatcar's [High Availability Kubernetes](https://www.flatcar.org/docs/latest/orchestrate/kubernetes/high-availability-kubernetes/)
guide (libvirt) for two Proxmox VE hosts: control plane on one, workers on the other.

## How a node is built

Two files describe the cluster, and nothing else names a node address:

- `nodes.conf` has a line per node: its role, IP, Proxmox host, VMID, size, GPU and
  extra labels.
- `k8s/clusters/homelab/cluster.env` has what the nodes share: the LAN's prefix
  length, gateway and DNS servers, the API VIP, and the pod and service CIDRs.

A node's OS config is built from layers in `butane/`, chosen by its role:

```
00_base-k8s            CRI-O + Kubernetes sysexts              (every node)
00_base-k8s-token      join token + CA hash, from secrets/     (every node)
00_base-k8s-pki        CA and service-account keys, secrets/   (control plane)
10_base-ha             SSH key, cluster-wide settings (versions, VIP, CIDRs)
20_base-ha-cp          keepalived, HAProxy, Cilium CLI         (control plane)
30_base-ha-init        kubeadm init + day-0 Cilium install     (first control plane node)
31_base-ha-join-cp     kubeadm join --control-plane            (other control plane nodes)
32_base-ha-join        kubeadm join                            (workers)
40_gpu-nvidia          NVIDIA driver + container runtime       (nodes with a gpu, see gpu.md)
```

The layers hold no addresses. `scripts/render-butane.sh` fills those in: it replaces
the `@NAME@` placeholders in the layers, and generates each node's own part (hostname,
network, kubelet arguments, keepalived peers) from its line in `nodes.conf`. To see what
a node gets, run `scripts/render-butane.sh node <name>`.

`make` compiles the result with `butane` into `ign/<node>.ign`, and `make up-<node>` uploads
that to the node's Proxmox host as a snippet and creates the VM from the Flatcar image
(`scripts/pve.sh`). Storage and bridge defaults live at the top of `scripts/pve.sh`
and can be overridden by env (e.g. `STORAGE=local-zfs make up`).

Bootstrap order happens on its own, following the order in `nodes.conf`: the first
control plane node runs `kubeadm init` and installs Cilium, each later one joins once
the one before it has a ready API, and workers join once the VIP answers. The first
also starts out holding the VIP, with the others backing it up in the same order. Progress:
`ssh core@192.168.1.21 journalctl -fu kubeadm -u cilium-install`.

## Adding or rebuilding a node

- **Add a worker:** .25–.30 are free. Add a line to `nodes.conf` (with the topology
  labels if it should use Proxmox volumes, see [storage.md](storage.md)), then
  `make up-<node>`.
- **Add a control plane node:** add its line after the existing ones, then rebuild the
  other control plane nodes one at a time too: each lists the others as keepalived
  peers and HAProxy backends.
- **Rebuild a node:** `make down-<node> up-<node>`. Rebuilding a *control plane* node
  also needs its old etcd member removed first (see below).
- **Use another network:** change `cluster.env` and the IPs in `nodes.conf`, for a new
  cluster only. Until the workloads read `cluster.env` as well, the addresses they name
  have to be changed by hand; the file lists them.
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
