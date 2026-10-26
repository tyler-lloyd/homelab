# Flatcar HA Kubernetes on Proxmox

Adapted from Flatcar's [High Availability Kubernetes](https://www.flatcar.org/docs/latest/orchestrate/kubernetes/high-availability-kubernetes/)
guide (libvirt) for two Proxmox VE hosts: control plane on one, workers on the other.

| Node        | IP           | Proxmox host | VMID |
| ----------- | ------------ | ------------ | ---- |
| API VIP     | 192.168.1.20 | (keepalived) |      |
| k8s-cp1     | 192.168.1.21 | 192.168.1.10 | 121  |
| k8s-cp2     | 192.168.1.22 | 192.168.1.10 | 122  |
| k8s-cp3     | 192.168.1.23 | 192.168.1.10 | 123  |
| k8s-worker1 | 192.168.1.24 | 192.168.1.11 | 124  |

.25–.30 are free for more workers (copy `butane/k8s-worker1.yaml` and add a line to `nodes.conf`). The API is served at `https://192.168.1.20:6444`
(HAProxy on every control plane node → kube-apiserver `:6443` on each).

Stack: Flatcar stable, Kubernetes v1.37.1 + CRI-O v1.37.2, keepalived and HAProxy
(all as [sysext bakery](https://extensions.flatcar.org) extensions), Cilium 1.20.2
replacing kube-proxy. Pods use 100.100.0.0/16, services 172.16.0.0/16.

## Usage

Needs `butane` locally and root SSH to both Proxmox hosts. On each host, the `local`
storage must allow snippets: `pvesm set local --content <existing types>,snippets`.

```sh
make secrets      # once per cluster: CAs + join token -> butane/00_base-k8s-{token,pki}.yaml
make              # build ign/*.ign
make image        # fetch + GPG-verify the Flatcar Proxmox image on both hosts
make up           # create + start all VMs; the cluster bootstraps itself
make kubeconfig   # then: KUBECONFIG=./kubeconfig kubectl get nodes
```

`make status`, `make up-<node>` / `make down-<node>` act on single nodes. `make down`
destroys every VM. Storage/bridge/gateway defaults live at the top of
`scripts/pve.sh` and can be overridden by env (e.g. `STORAGE=local-zfs make up`).

Bootstrap order happens on its own: cp1 runs `kubeadm init` and installs Cilium,
cp2 joins once cp1's API is ready, cp3 once cp2's is, and workers once the VIP
answers. Progress: `ssh core@192.168.1.21 journalctl -fu kubeadm -u cilium-install`.

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

The files in `butane/00_base-k8s-{token,pki}.yaml`, `certs/` and `ign/` hold
cluster secrets and are git-ignored. New secrets mean a new cluster (`FORCE=1 make secrets`).
