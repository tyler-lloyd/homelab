# GPU nodes

A node gets a GPU by passing its PCI address in the `gpu` column of `nodes.conf`
(`-` for none). That does three things: `pve.sh` passes the device through
(`hostpci0 <addr>,pcie=1`, all functions, ballooning off), the node's config merges
`butane/40_gpu-nvidia.yaml`, and its kubelet sets the label
`nvidia.com/gpu.present=true`. The layer installs Flatcar's prebuilt NVIDIA driver sysext
(`nvidia-drivers-570-open`) and the NVIDIA container toolkit, and makes
`nvidia-container-runtime` (wrapping crun) the node's default CRI-O runtime.
Once the node has joined, `make gpu-plugin` installs the NVIDIA device plugin
(`k8s/manifests/nvidia-device-plugin.yaml`, the one manifest Flux doesn't apply), and
the node advertises `nvidia.com/gpu: 1`.

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
