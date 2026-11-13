#!/usr/bin/env bash
# Manage the cluster VMs on the Proxmox hosts listed in nodes.conf.
#
#   pve.sh image <pve_host>   download + GPG-verify the Flatcar Proxmox VE image on a host
#   pve.sh create <node>      upload the node's Ignition snippet, then create and start its VM
#   pve.sh destroy <node>     stop and delete the node's VM and snippet
#   pve.sh status             show the state of every node's VM

set -euo pipefail

cd "$(dirname "$0")/.."

PVE_USER=${PVE_USER:-root}
CHANNEL=${CHANNEL:-stable}
STORAGE=${STORAGE:-local-lvm}
BRIDGE=${BRIDGE:-vmbr0}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-local}
SNIPPET_DIR=${SNIPPET_DIR:-/var/lib/vz/snippets}
IMAGE_DIR=${IMAGE_DIR:-/var/lib/vz/template/flatcar}
IMAGE=$IMAGE_DIR/flatcar_production_proxmoxve_image.img

# The LAN's prefix length, gateway and DNS servers
# shellcheck source=../k8s/clusters/homelab/cluster.env
. k8s/clusters/homelab/cluster.env

pve() {
  local host=$1
  shift
  ssh -o BatchMode=yes "$PVE_USER@$host" "$@"
}

# A rebuilt node reuses its IP but gets a new host key. Serialized because
# ssh-keygen -R rewrites known_hosts and parallel make runs would race.
forget_host_key() {
  flock "${XDG_RUNTIME_DIR:-/tmp}/pve-known-hosts.lock" ssh-keygen -R "$ip" >/dev/null 2>&1 || true
}

nodes() { awk '!/^#/ && NF { print $1 }' nodes.conf; }

lookup() {
  read -r name _ vmid host ip cores memory disk gpu _ < <(awk -v n="$1" '!/^#/ && $1 == n' nodes.conf) || true
  if [[ ${name:-} != "$1" ]]; then
    echo "unknown node '$1' (see nodes.conf)" >&2
    exit 1
  fi
  gpu=${gpu:--}
}

# Prints the host driver bound to $gpu on $host, "none", or "missing"
gpu_driver() {
  pve "$host" "d=/sys/bus/pci/devices/$gpu.0; if [ ! -e \$d ]; then echo missing; elif [ -L \$d/driver ]; then basename \$(readlink \$d/driver); else echo none; fi"
}

# Prints "missing", "ours" or "foreign" depending on what owns $vmid on $host
vm_owner() {
  pve "$host" "if ! qm status $vmid >/dev/null 2>&1; then echo missing; elif qm config $vmid | grep -qx 'name: $name'; then echo ours; else echo foreign; fi"
}

image() {
  local host=$1
  local url="https://$CHANNEL.release.flatcar-linux.net/amd64-usr/current/flatcar_production_proxmoxve_image.img"
  pve "$host" bash -s <<EOF
set -euo pipefail
mkdir -p '$IMAGE_DIR'
cd '$IMAGE_DIR'
export GNUPGHOME='$IMAGE_DIR/gnupg'
mkdir -p -m 0700 "\$GNUPGHOME"
curl -fsSL https://www.flatcar.org/security/image-signing-key/Flatcar_Image_Signing_Key.asc | gpg --quiet --import
curl -fsSL -o image.img.tmp '$url'
curl -fsSL -o image.img.sig '$url.sig'
gpg --verify image.img.sig image.img.tmp
mv image.img.tmp '$IMAGE'
rm -f image.img.sig
curl -fsSL '${url%/*}/version.txt' | grep '^FLATCAR_VERSION=' > version.txt
echo "$host: \$(cat version.txt) at $IMAGE"
EOF
}

create() {
  lookup "$1"
  local ign="ign/$name.ign"
  if [[ ! -f $ign ]]; then
    echo "$ign is missing; run 'make' first" >&2
    exit 1
  fi
  case $(vm_owner) in
    missing) ;;
    ours) echo "$name: VM $vmid already exists on $host, skipping"; return ;;
    *) echo "$name: VM $vmid on $host belongs to another VM; pick a different vmid in nodes.conf" >&2; exit 1 ;;
  esac

  # Passed-through memory is pinned, so ballooning is off for GPU nodes. The GPU
  # must already be on vfio-pci: Proxmox would otherwise try to rip it away from
  # a live host driver (e.g. nvidia serving LXC containers).
  local gpu_args=
  if [[ $gpu != - ]]; then
    local driver
    driver=$(gpu_driver)
    case $driver in
      vfio-pci|none) ;;
      missing) echo "$name: no PCI device $gpu on $host" >&2; exit 1 ;;
      *) echo "$name: $gpu on $host is bound to '$driver', not vfio-pci; see docs/gpu.md" >&2; exit 1 ;;
    esac
    gpu_args="--hostpci0 $gpu,pcie=1 --balloon 0"
  fi

  scp -q "$ign" "$PVE_USER@$host:$SNIPPET_DIR/$name.ign"
  pve "$host" bash -s <<EOF
set -euo pipefail
test -f '$IMAGE' || { echo "$IMAGE missing on $host; run 'make image'" >&2; exit 1; }
qm create $vmid --name $name --tags k8s --onboot 1 \\
  --bios ovmf --efidisk0 $STORAGE:1 \\
  --arch x86_64 --machine q35 --args '-machine sata=off' \\
  --cpu host --cores $cores --memory $memory \\
  --net0 virtio,bridge=$BRIDGE \\
  --ipconfig0 ip=$ip/$LAN_PREFIX_LEN,gw=$LAN_GATEWAY --nameserver '${DNS_SERVERS//,/ }' \\
  --virtio0 $STORAGE:0,import-from=$IMAGE,discard=on --boot order=virtio0 \\
  --scsihw virtio-scsi-pci --scsi0 $STORAGE:cloudinit \\
  --cicustom user=$SNIPPET_STORAGE:snippets/$name.ign \\
  --serial0 socket --agent enabled=1 $gpu_args \\
  2>&1 | grep -v '^transferred '
qm disk resize $vmid virtio0 $disk
qm start $vmid
EOF
  forget_host_key
  echo "$name: VM $vmid started on $host ($ip)"
}

destroy() {
  lookup "$1"
  case $(vm_owner) in
    missing) echo "$name: no VM $vmid on $host" ;;
    ours)
      pve "$host" "qm stop $vmid --skiplock 1 >/dev/null 2>&1 || true; qm destroy $vmid --purge 1 --destroy-unreferenced-disks 1"
      echo "$name: VM $vmid destroyed on $host"
      ;;
    *) echo "$name: VM $vmid on $host is not named $name; refusing to destroy it" >&2; exit 1 ;;
  esac
  pve "$host" rm -f "$SNIPPET_DIR/$name.ign"
  forget_host_key
}

status() {
  local n
  for n in $(nodes); do
    lookup "$n"
    printf '%-12s %-4s %-13s %-13s %s\n' "$name" "$vmid" "$host" "$ip" "$(pve "$host" "qm status $vmid 2>/dev/null || echo 'status: missing'")"
  done
}

case ${1:-} in
  image) image "${2:?pve host required}" ;;
  create) create "${2:?node name required}" ;;
  destroy) destroy "${2:?node name required}" ;;
  status) status ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
