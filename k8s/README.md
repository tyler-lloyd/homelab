# Flatcar HA Kubernetes on Proxmox

Adapted from Flatcar's [High Availability Kubernetes](https://www.flatcar.org/docs/latest/orchestrate/kubernetes/high-availability-kubernetes/)
guide (libvirt) for two Proxmox VE hosts: control plane on one, workers on the other.

| Node        | IP           | Proxmox host | VMID | GPU |
| ----------- | ------------ | ------------ | ---- | --- |
| API VIP     | 192.168.1.20 | (keepalived) |      |     |
| k8s-cp1     | 192.168.1.21 | 192.168.1.10 | 121  |     |
| k8s-cp2     | 192.168.1.22 | 192.168.1.10 | 122  |     |
| k8s-cp3     | 192.168.1.23 | 192.168.1.10 | 123  |     |
| k8s-worker1 | 192.168.1.24 | 192.168.1.11 | 124  | RTX A400 ([GPU nodes](#gpu-nodes)) |

.25–.30 are free for more workers (copy `butane/k8s-worker1.yaml`, dropping the GPU
bits, and add a line to `nodes.conf`). The API is served at `https://192.168.1.20:6444`
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

## GPU nodes

A node gets a GPU by passing its PCI address in the `gpu` column of `nodes.conf`
(`pve.sh` adds `hostpci0 <addr>,pcie=1`, all functions, ballooning off) and by merging
`ign/40_gpu-nvidia.ign` in its `butane/<node>.yaml` and adding
`--node-labels=nvidia.com/gpu.present=true` to its `KUBELET_EXTRA_ARGS`
(see `k8s-worker1.yaml`). That layer installs Flatcar's prebuilt NVIDIA driver sysext
(`nvidia-drivers-570-open`) and the NVIDIA container toolkit, and makes
`nvidia-container-runtime` (wrapping crun) the node's default CRI-O runtime.
Once the node has joined, `make kubeconfig gpu-plugin` installs the NVIDIA device plugin,
and the node advertises `nvidia.com/gpu: 1`.

**Proxmox host prep (once, on 192.168.1.11).** Passthrough needs the GPU bound to
`vfio-pci` instead of the host's `nvidia` driver, and `make up-<node>` refuses to start
the VM until it is. The jellyfin LXC (CT 100) currently uses the GPU *through* the host
driver, so this takes the GPU away from it. One GPU can serve the host or a VM, not both.
Do it when jellyfin moves into the cluster:

```sh
# Remove the GPU from CT 100 first: it won't start while dev0..dev3 point at missing
# /dev/nvidia* (its optional /dev/dri lxc.* lines are harmless and can stay)
pct set 100 --delete dev0,dev1,dev2,dev3

# Claim the RTX A400 (GPU + its HDMI audio, IOMMU group 25) with vfio-pci at boot
cat > /etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=10de:25b2,10de:2291
softdep nvidia pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > /etc/modules-load.d/vfio.conf
update-initramfs -u -k all && reboot

# Afterwards both functions should say "Kernel driver in use: vfio-pci"
lspci -nnk -s 0a:00
```

The host's NVIDIA driver can stay installed. To give the GPU back to the host, undo the
two files above and reboot. The VM's memory is pinned while the GPU is attached
(32 GiB of the host's 64).

**Using it from a pod.** Request the GPU and the video driver capabilities (NVENC/NVDEC):

```yaml
spec:
  nodeSelector:
    nvidia.com/gpu.present: "true"
  containers:
    - name: jellyfin
      image: jellyfin/jellyfin
      env:
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: all
      resources:
        limits:
          nvidia.com/gpu: 1
```

Then pick NVENC under Dashboard → Playback → Transcoding in Jellyfin. To check the
node: `ssh core@192.168.1.24 nvidia-smi`, `journalctl -u nvidia`.

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
