# RustDesk Helm Chart

A publicly published Helm chart for the self-hosted RustDesk server, developed and validated against k3s with MetalLB.

## Language

### The upstream product

**RustDesk Server**:
The self-hosted, AGPL-licensed server that RustDesk clients register and connect through. Unqualified, this term always means the open-source edition — the only edition this chart currently packages.
_Avoid_: OSS server, rustdesk-server-oss

**RustDesk Server Pro**:
The separately licensed commercial edition, which adds a web console and user management on top of the same two roles. Out of scope for now, but the chart's values are shaped so it can be added without renaming existing keys.
_Avoid_: Pro server, enterprise edition

### The two roles

**hbbs**:
The role that registers client IDs and brokers direct peer-to-peer connections between them. The stateful half: it owns the database and the key pair.
_Avoid_: ID server, rendezvous server, signal server, broker

**hbbr**:
The role that forwards traffic between two peers when they cannot reach each other directly.
_Avoid_: relay server, relay, turn server

Roles are named after the upstream binaries rather than after what they do, because every upstream flag, log line, and support thread uses those names.

**Key pair**:
The Ed25519 pair that identifies a RustDesk Server installation. Clients pin its public half at enrollment. Losing or rotating it silently disconnects every enrolled client.
_Avoid_: server key, host key, signing key, id_ed25519

The two halves are not interchangeable and are not held by the same components. Only hbbs holds the **private key**, which it uses to sign the identity it returns to clients. hbbr and every client hold only the **public key**, which they compare as an opaque string to decide whether a relay session is authorized.

### Upstream images

**Classic image**:
The `scratch`-based upstream image holding the two role binaries, one per container. The image this chart deploys.
_Avoid_: docker-classic, the scratch image

**s6 image**:
The upstream busybox + s6-overlay image that supervises both roles inside a single container. Not used for deployment; it is the only official image carrying `rustdesk-utils`.
_Avoid_: the supervised image, the all-in-one image

### This chart's concepts

**Relay-only release**:
An installation of this chart with hbbs disabled, providing additional relay capacity at its own address. The only supported way to add relay capacity, since a single relay cannot be scaled by replica count.
_Avoid_: relay node, relay worker, secondary relay
