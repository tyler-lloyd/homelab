# Networking

Cilium replaces kube-proxy and is the CNI (see [flux.md](flux.md#cilium) for how it is
installed and changed). Pods use 100.100.0.0/16, Services 172.16.0.0/16.

## LoadBalancer IPs (Cilium)

`type: LoadBalancer` Services get a LAN IP from 192.168.1.31–.40. Cilium hands out the
address (LB-IPAM), and one worker answers ARP for it (L2 announcements), so no
MetalLB is needed. Keep the range out of the router's DHCP pool.

```yaml
metadata:
  annotations:
    lbipam.cilium.io/ips: 192.168.1.31   # pin an address; omit for the next free one
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster        # the default; don't use Local (see below)
```

- **One node holds each IP**, chosen through a Kubernetes lease among nodes matching
  `k8s/infrastructure/configs/cilium/l2-announcement-policy.yaml` (workers only). If that node dies,
  another takes over after 10–20 s.
- **Don't use `externalTrafficPolicy: Local`.** L2 announcements don't check which nodes
  run the Service's pods. With `Local`, the node holding the IP may have no pod and
  will drop the traffic.
- To check: `kubectl get svc -A | grep LoadBalancer` lists the IPs, and
  `kubectl -n kube-system get lease | grep l2announce` shows which node holds each one.

## Per-pod WireGuard tunnels (zora)

[zora](https://github.com/tyler-lloyd/zora) gives a pod its own WireGuard tunnel:
put a wg-quick config in a Secret under the key `wg0.conf`, and annotate the pod
with `zora.io/wireguard-secret: <secret name>`. Traffic to pods, Services and
nodes stays out of the tunnel.

- **Enabling a namespace:** zora can read Secrets only in the namespaces listed
  under `secrets.namespaces` in `k8s/infrastructure/controllers/zora/helmrelease.yaml`.
  The namespace has to exist first, so add it in the same commit or an earlier one.
- **Excluded namespaces** (`excludeNamespaces`) never go through zora. Pods in
  every other namespace do, annotated or not, so if a node's `zora-agent` is down,
  new pods there wait in `ContainerCreating` until it is back. Running pods are
  unaffected.
- **Cilium** must keep `cni.exclusive: false`, or it removes zora from the nodes'
  CNI config. zora's agents then report not-ready and say why.
- **Upgrading:** change the tag in
  `k8s/infrastructure/controllers/zora/gitrepository.yaml`.
- **Removing:** delete `k8s/infrastructure/controllers/zora` from git. Flux uninstalls the release,
  which takes zora out of every node's CNI config first. Pods keep their tunnels
  until they restart.
