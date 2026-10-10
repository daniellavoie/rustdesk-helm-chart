# An opt-in Tailscale sidecar, as a deliberate exception to ADR-0008

ADR-0008 keeps vendor integrations out of the chart. This adds one: when a role's pre-auth key
Secret is referenced (`hbbs.tailscale.authKey.existingSecret`, `hbbr.tailscale.authKey.existingSecret`),
that role's pod gets a Tailscale sidecar and joins a tailnet as its own node, on Tailscale's
control plane or a Headscale server via `tailscale.loginServer`.

It is an exception rather than a reversal because it fails none of ADR-0008's tests. That ADR
rejected generating resources for a port-forward controller because doing so bound the chart to
an unreleased, single-maintainer `v1alpha1` CRD. The sidecar adds no CRD and no controller: it
is the official `tailscale/tailscale` image, configured through its documented environment
variables, off by default, and nothing renders for users who do not set a key.

## Why a sidecar rather than a subnet router

A tailnet can already reach a Service through a subnet router. That path SNATs, so hbbs sees
the router as the source of every peer and hands out unusable endpoints for hole punching: the
same silent relay fallback `docs/exposure.md` describes for `externalTrafficPolicy: Cluster`. A
sidecar puts the tailnet address on the pod itself, so the real source arrives intact.

## Decisions inside the feature

- **Kernel networking, privileged by default.** Userspace mode would deliver every tailnet
  connection from 127.0.0.1, defeating the point above. Kernel mode opens `/dev/net/tun`, and on
  containerd an unprivileged container can create that node but not open it; this was confirmed
  on k3s 1.31 (`tstun.New: operation not permitted` with `NET_ADMIN` and `MKNOD`). Only the
  sidecar is privileged, and `tailscale.securityContext` lets clusters with a tun device plugin
  replace it.
- **All or nothing.** With hbbs on the tailnet and hbbr off it, clients reach the ID server but
  not the relay, and the failure surfaces much later. The chart refuses that configuration.
- **Each role is its own node, so the relay is named rather than derived.** ADR-0005's
  client-side derivation (`<ID server host>:<port + 1>`) assumes both roles share an address.
  On a tailnet they do not. The chart sets the hostnames, so given the tailnet's DNS suffix
  (`tailscale.magicDNSDomain`) it knows hbbr's name before the pod exists and passes
  `-r <hbbr hostname>.<domain>:<port>` at install time. hbbs never resolves it; clients do,
  through Tailscale DNS. An explicit `hbbs.config.relayServers` still wins, and NOTES warns
  when neither is set. Waiting for hbbr to join and writing its IP back was rejected: it
  needs a second deploy, and tailnet IPs change if a node is ever re-registered.
- **State in a Secret the chart creates.** tailscaled keeps its node identity in
  `<role>-tailscale-state`, which the chart declares without data and keeps on uninstall, like
  the key pair. Restarts and reinstalls return as the same node at the same address. Because the
  chart creates it, the Role needs only `get`, `update` and `patch` on those names, never a
  namespace-wide `create`.
- **The API token reaches the sidecar only.** Pods keep `automountServiceAccountToken: false`;
  the sidecar mounts a projected token, so the RustDesk containers still have no API access.
- **Not a native sidecar.** `restartPolicy: Always` init containers need Kubernetes 1.28+, and
  the chart supports 1.26. The sidecar is an ordinary container.

## Consequences

- The chart now names a vendor in its values. Anyone auditing for ADR-0008 should read this
  record alongside it.
- A privileged container exists in these pods when the feature is on.
- NetworkPolicy, when enabled, opens all egress for a role with a sidecar: the coordination
  server, DERP relays and peers have no addresses known at install time.
- The tailnet path is not covered by CI: it needs a reachable coordination server and a real
  key. CI renders and validates the manifests only.
