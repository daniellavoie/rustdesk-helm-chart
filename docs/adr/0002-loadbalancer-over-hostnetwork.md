# Default to LoadBalancer with externalTrafficPolicy: Local, not hostNetwork

hbbs treats the observed source address of a peer's UDP packet as that peer's public NAT
endpoint, and hands it verbatim to the other peer to dial for hole punching. There is no
PROXY-protocol support on port 21116. Behind any SNAT-ing hop, every peer appears to come from
the same address, the `same_intranet` shortcut misfires for all of them, and every session
silently falls back through the relay. Preserving the client source IP is therefore a
correctness requirement, not a nicety.

Upstream's own documentation and all its compose examples use `--net=host`. We default instead
to MetalLB `LoadBalancer` Services with `externalTrafficPolicy: Local`, and support
`hostNetwork: true` as an explicit opt-in.

## Consequences

- The default path stays inside the LoadBalancer abstraction the target platform (k3s + MetalLB)
  already provides, instead of pinning pods to nodes and claiming ports 21115-21119 cluster-wide.
- It is strictly more moving parts than hostNetwork, and the failure mode of a misconfigured
  `externalTrafficPolicy` is silent: everything still works, just relayed. Documentation and
  release notes must call this out.
- CI cannot cover this path. The install test runs on k3d, which has no MetalLB, so it must use
  a ClusterIP/NodePort overlay — leaving the default path exercised only on real clusters.
