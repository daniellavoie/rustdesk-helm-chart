# Exposing the server

RustDesk is unusual to expose on Kubernetes for two reasons: it needs TCP **and** UDP on the
same port number, and it needs the client's real source address. Everything below follows from
those two facts.

## Why the source address matters

hbbs records the observed source address of a client's UDP packet as that peer's public NAT
endpoint, and hands it to the other peer to dial for hole punching. If anything rewrites that
address, every peer looks like it comes from the same place, hole punching hands out an
unroutable endpoint, and every session falls back through the relay.

Nothing errors. Clients connect, sessions work, and all your peer-to-peer traffic quietly
becomes relay traffic. This is the single most common way to misconfigure a RustDesk server,
and the reason `externalTrafficPolicy` is not a matter of taste here.

## Option 1: LoadBalancer (default)

```yaml
hbbs:
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
    loadBalancerIP: "192.168.1.20"
hbbr:
  service:
    type: LoadBalancer
    loadBalancerIP: "192.168.1.21"
```

`Local` preserves the source address, and a load balancer that honours it announces the
service only from nodes that actually have the pod. This is the simplest correct arrangement.

Two Services means two addresses. If you are short on address space, some implementations can
share one — MetalLB does it with a matching `metallb.universe.tf/allow-shared-ip` annotation
on both Services, set through `hbbs.service.annotations` and `hbbr.service.annotations`. The
two roles have no overlapping ports, so sharing is safe. It is not the default because that
annotation is implementation-specific.

## Option 2: NodePort behind an external port forwarder

Common in home labs: a router or a controller forwards public ports to node ports.

```yaml
hbbs:
  service:
    type: NodePort
    externalTrafficPolicy: Local
    annotations: {}          # whatever your forwarder reads
  nodeSelector:
    kubernetes.io/hostname: node-1
hbbr:
  service:
    type: NodePort
    externalTrafficPolicy: Local
  nodeSelector:
    kubernetes.io/hostname: node-1
```

This chart has no integration with any particular forwarder. Drive yours with
`service.annotations`, or create its own resources separately.

### The trap: forwarders cannot see Endpoints

`externalTrafficPolicy: Local` means **only the node currently running the pod answers on the
node port**. Every other node drops the traffic, silently.

Most external forwarders — router rules, port-forward controllers, simple L4 balancers —
resolve a destination once and target a fixed address. They do not watch Endpoints and have no
idea where your pod is. Some pick a node by a stable heuristic such as "lowest-named ready
node", which is not the same thing as "a node running the pod". So:

- If the pod is not on the targeted node, the forward points at a black hole.
- Nothing reports an error. The rule exists, the node is healthy, the port is simply closed.
- Reconciliation, if any, is usually on a timer measured in minutes.

**Pin both ends.** Put a `nodeSelector` on the pod and target that same node in the forwarder.
On k3s with the default `local-path` storage this is barely a constraint: hbbs's ReadWriteOnce
volume already ties it to one node.

**Do not fix this with `externalTrafficPolicy: Cluster`.** It makes every node answer, which
looks like a solution, and it rewrites the client source address — see the top of this page for
what that costs. A blackhole is loud; a relayed-everything install is silent and permanent.

### The other trap: one port, two protocols

Port 21116 needs a TCP forward **and** a UDP forward. Kubernetes allocates a *separate* node
port for each protocol, even though the service port number is the same:

```
kubectl get svc <release>-hbbs \
  -o jsonpath='{range .spec.ports[*]}{.name}{"\t"}{.port}/{.protocol}{"\t-> node:"}{.nodePort}{"\n"}{end}'
```

Some forwarders refuse two rules on the same external port even when the protocols differ, and
some treat "both protocols" as a single option that does not work as advertised. Verify that
UDP is genuinely forwarded — it is the one carrying registration and heartbeat, and it is the
one most connectivity checks skip. `nc -zvu <host> 21116`.

If you need fixed node ports rather than allocated ones, set `hbbs.service.nodePorts` and
`hbbr.service.nodePorts`, and widen the cluster's node-port range if you want them to match the
public numbers.

## Option 3: hostNetwork

```yaml
hbbs:
  hostNetwork: true
hbbr:
  hostNetwork: true
```

What upstream's own documentation recommends. The pods bind 21115-21117 directly on the node,
so the source address arrives untouched and `externalTrafficPolicy` stops being relevant. The
forwarder then targets `node:21116` one-to-one.

The costs are real: the ports are claimed cluster-wide on that node, the pods are pinned to
wherever those ports are free, and a port collision is a scheduling failure rather than a
configuration error.

## Option 4: a tailnet, through the Tailscale sidecar

For servers that only your own devices should reach, each role can join a tailnet (Tailscale,
or Headscale) as its own node. Nothing is exposed to the internet, and no port forwarding is
needed.

```yaml
tailscale:
  loginServer: https://headscale.example.com   # omit for Tailscale's own control plane
  magicDNSDomain: headscale.example.com         # Headscale's dns.base_domain
hbbs:
  service:
    type: ClusterIP
  tailscale:
    authKey:
      existingSecret: rustdesk-hbbs-tailscale   # holds a pre-auth key under `authkey`
hbbr:
  service:
    type: ClusterIP
  tailscale:
    authKey:
      existingSecret: rustdesk-hbbr-tailscale
```

Why a sidecar and not a subnet router: a subnet router SNATs, so hbbs would see the router as
every peer's source, the same silent relay fallback described above. The sidecar gives the pod
its own tailnet address and runs in kernel mode, so the peer's real address arrives intact.

Three things to know:

1. **Both roles or neither.** The chart refuses a release where only one role has a key.
2. **The relay is named, not derived.** hbbs and hbbr are separate nodes with separate
   addresses, so the relay a client would derive from the ID server address points at hbbs.
   With `tailscale.magicDNSDomain` set, the chart passes hbbs
   `<hbbr hostname>.<domain>:<hbbr.port>` at install time; nothing needs configuring after
   the pods join. Clients set the ID server to `<hbbs hostname>.<domain>` and the key, and
   leave the relay empty. They resolve both names through Tailscale DNS, which clients accept
   by default. Without a DNS suffix, set `hbbs.config.relayServers` to hbbr's tailnet address
   instead (NOTES prints how to read it).

   Names are only predictable while unique: if an older node on the tailnet already has the
   hostname, the coordination server renames the new one. Keeping the state Secrets (the
   default) avoids that across reinstalls.
3. **The sidecar is privileged.** Kernel mode needs `/dev/net/tun`, which containerd does not
   let an unprivileged container open. See `tailscale.securityContext` and ADR-0009.

Node state lives in a `<role>-tailscale-state` Secret that the chart creates and keeps on
uninstall, so the nodes keep their addresses across restarts, upgrades and reinstalls. Use a
reusable pre-auth key only if you accept that anyone holding it can join your tailnet; a
single-use key is enough, since it is only spent on the first login.

## Verifying you got it right

A working session proves less than you would think, because the relay fallback hides the
failure this page is about.

1. Confirm UDP arrives: `nc -zvu <your public host> 21116`.
2. Check what hbbs sees. In `kubectl logs <hbbs-pod>`, peers should register from *different*
   addresses. If they all share one — a node IP, or something like `10.42.0.1` — the source is
   being rewritten and you are relaying everything.
3. Confirm a session is actually direct. In the RustDesk client, the connection indicator
   distinguishes a direct connection from a relayed one. Test from a network outside your own.
