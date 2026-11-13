# Storage (Proxmox CSI)

PVCs are provisioned by the [Proxmox CSI plugin](https://github.com/sergelogvinov/proxmox-csi-plugin)
as disks on the Proxmox host's own storage, hot-plugged into the VM running the pod.
The default StorageClass `proxmox-local-lvm` uses `local-lvm` on 192.168.1.11 (NVMe
thin pool). A disk is separate from its VM, so it survives a rebuild with
`make down-k8s-worker1 up-k8s-worker1`, and the plugin attaches it to the new VM.
The disks show up on the host as `vm-9999-pvc-<uuid>`.

- **Local storage pins the volume to one Proxmox host.** A pod using it only runs on
  VMs on that host. That's every worker today.
- **`reclaimPolicy: Retain`**: deleting a PVC, including Flux pruning one, leaves the
  disk in place. To really delete it, delete the PV and then run
  `pvesm free local-lvm:vm-9999-pvc-<uuid>` on the host.
- **Node labels:** nodes need `topology.kubernetes.io/region=pve` (the region name in
  `k8s/infrastructure/controllers/proxmox-csi/config.sops.yaml`) and
  `topology.kubernetes.io/zone=pve` (the Proxmox node name, which is case-sensitive).
  The kubelet sets them from the node's `labels` column in `nodes.conf`, so give a new
  worker on that host the same two. The node plugin only runs on nodes in the `pve` region.
- **Workers on 192.168.1.10** would need a second entry under `clusters:` in the
  config, with a token created on that host and its own region name.

The API token is `kubernetes-csi@pve!kubernetes-csi` with role `CSI`
(`VM.Audit VM.Config.Disk Datastore.Allocate Datastore.AllocateSpace Datastore.Audit`)
on `/`. It uses privilege separation, so the token needs its own ACL: granting the
role to the user alone isn't enough. To edit the config, run
`sops k8s/infrastructure/controllers/proxmox-csi/config.sops.yaml`.
