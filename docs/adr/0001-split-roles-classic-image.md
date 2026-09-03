# Split hbbs and hbbr into separate workloads, using the classic image

Upstream publishes two images: a `scratch`-based "classic" image containing the `hbbs` and
`hbbr` binaries (one per container), and an s6-overlay image that supervises both roles inside
a single container. Every widely-used community chart uses the single-pod shape.

We use the classic image and give each role its own workload, independently enableable, because
the two roles have incompatible lifecycles. hbbs is pinned to a single replica forever — peer
liveness and the pending-punch map are in-memory only, SQLite runs a connection pool of 1, and
the volume is ReadWriteOnce. hbbr holds no durable state and can be deployed on its own, in
another cluster or another region, as a relay-only release. The single-pod shape forecloses
that permanently.

## Consequences

- A relay-only release can be installed anywhere and added to hbbs's `-r` list, with no
  separate chart.
- **hbbr is nonetheless pinned to one replica per release.** It pairs the two peers of a session
  by UUID within a single process, so two replicas behind one Service silently fail to pair
  whenever the peers land on different pods. `sessionAffinity: ClientIP` does not help: the two
  peers have different client IPs by definition. Horizontal relay capacity comes from additional
  relay-only releases at distinct addresses, listed in `hbbs.relayServers` — which also means
  scaling out takes an operator off ADR-0005's empty-`-r` default.
- The classic image is `FROM scratch`: no shell, no `/etc/passwd`, and no `rustdesk-utils`.
  `kubectl exec` and `kubectl cp` do not work against these containers, and `exec` probes are
  impossible.
- We give up the s6 image's healthcheck and its `KEY_PUB`/`KEY_PRIV` conveniences, both of
  which are shell scripts in the image rather than features of the binaries.
