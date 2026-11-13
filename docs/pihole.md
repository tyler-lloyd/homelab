# Pi-hole

DNS for the LAN at **192.168.1.31** (53/udp+tcp), with the web UI at
http://192.168.1.31/admin. It's a single pod (`k8s/apps/pihole/`) with `/etc/pihole` on a
2 GiB `proxmox-local-lvm` volume, forwarding to 1.1.1.1 and 9.9.9.9.

- **Settings given as `FTLCONF_*` variables in `deployment.yaml`** (upstreams,
  listening mode, password) are read-only in the web UI, so change them in git.
  Blocklists, allow/deny lists and local DNS records are managed in the UI and stored
  on the volume.
- **To read the web password:**
  `sops -d k8s/apps/pihole/admin.sops.yaml | grep password`. To change it, run
  `sops k8s/apps/pihole/admin.sops.yaml`, then restart the pod after Flux applies it.
- **Point the router's DHCP DNS server at 192.168.1.31**, with no fallback server,
  since clients that fall back skip blocking. The nodes and Proxmox hosts keep
  1.1.1.1/8.8.8.8, so a down cluster can still pull images to bring Pi-hole back.
- **Client IPs:** the query log shows real client IPs while the pod runs on the node
  holding .31, which is always true with a single worker. With more workers it may show
  a node IP instead (see [LoadBalancer IPs](networking.md#loadbalancer-ips-cilium)).
