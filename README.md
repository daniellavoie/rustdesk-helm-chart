# rustdesk-server

Self-hosted RustDesk server (hbbs + hbbr), with durable key management and source-IP preserving networking.

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.1.16](https://img.shields.io/badge/AppVersion-1.1.16-informational?style=flat-square)

A Helm chart for the self-hosted [RustDesk server](https://github.com/rustdesk/rustdesk-server),
built around the three things that make RustDesk unusual to run on Kubernetes: it needs the
client's real source IP, its identity lives in a key pair that must never change, and only one
of its two roles can be scaled.

## Install

```bash
helm install rustdesk oci://ghcr.io/daniellavoie/helm-charts/rustdesk-server
```

Then follow the notes printed on install: read the public key out of the Secret, point clients
at your address, and leave their relay field empty.

## What this chart does differently

**The key pair survives.** The installation's identity is an Ed25519 pair that clients pin at
enrollment; if it changes, every enrolled client stops connecting. An init hook generates it
into a Secret that Helm does not own, so it survives `helm uninstall` and is reused on
reinstall. The volume is only a cache of that Secret, so losing the volume costs nothing.
Bring your own with `key.existingSecret` — see [migration](docs/migration.md).

**The relay validates clients, without holding the private key.** Upstream leaves relay
validation off by default, which makes the relay usable by anyone who finds it. This chart
turns it on. hbbr only ever receives the public half — it compares an opaque string and
performs no cryptography — so the private key never leaves the hbbs pod.

**Source IP preservation is treated as correctness.** `externalTrafficPolicy: Local` is the
default because hbbs stores the observed packet source as a peer's NAT endpoint. Get this
wrong and everything still works, just relayed, forever. `hostNetwork` is supported as an
opt-in.

**The roles are separate workloads.** hbbs is a single-replica StatefulSet with a volume; hbbr
is stateless and can be deployed on its own as a relay-only release. Neither can be scaled by
replica count — see [ADR-0001](docs/adr/0001-split-roles-classic-image.md) for why the relay
in particular cannot.

## Requirements

Kubernetes 1.26 or newer. The floor is enforced in `Chart.yaml` because hbbs needs TCP and UDP
on the same port, and mixed-protocol LoadBalancer Services only became generally available in
1.26 — below that the UDP port is silently dropped and client registration never works.

Developed and validated against k3s with MetalLB.

## Ports

| Port | Protocol | Role | Purpose | Default |
|------|----------|------|---------|---------|
| 21115 | TCP | hbbs | NAT type test | on |
| 21116 | TCP | hbbs | Rendezvous, TCP hole punching | on |
| 21116 | **UDP** | hbbs | ID registration and heartbeat | on |
| 21117 | TCP | hbbr | Relay | on |
| 21118 | TCP | hbbs | WebSocket rendezvous (web client) | **off** |
| 21119 | TCP | hbbr | WebSocket relay (web client) | **off** |

21118 and 21119 are off because they accept `X-Real-IP` and `X-Forwarded-For` without
validation and overwrite the peer address with them. Enable them only behind a proxy that
overwrites both headers. This chart ships no Ingress —
[ADR-0006](docs/adr/0006-no-ingress-web-client-ports-off.md) explains why.

## Verifying the chart

Releases are signed with [cosign](https://docs.sigstore.dev/) keyless signing, tied to the
GitHub Actions workflow that built them:

```bash
cosign verify ghcr.io/daniellavoie/helm-charts/rustdesk-server:0.1.0 \
  --certificate-identity-regexp 'https://github.com/daniellavoie/rustdesk-helm-chart/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Documentation

- [Exposing the server](docs/exposure.md) — LoadBalancer, NodePort behind a port forwarder,
  hostNetwork, and the traps in each
- [Troubleshooting, by symptom](docs/troubleshooting.md) — start here when something is
  subtly wrong, which is how this software usually fails
- [Migrating an existing installation](docs/migration.md)
- [Architecture decisions](docs/adr/) — why the chart is shaped this way
- [Domain glossary](CONTEXT.md)

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| fullnameOverride | string | `""` | Fully overrides the generated resource name prefix. |
| hbbr.affinity | object | `{}` |  |
| hbbr.config.downgradeStartCheck | int | `1800` | Seconds before a connection becomes eligible for downgrade (DOWNGRADE_START_CHECK). |
| hbbr.config.downgradeThreshold | string | `"0.66"` | Fraction of `singleBandwidth` that triggers a downgrade (DOWNGRADE_THRESHOLD). |
| hbbr.config.limitSpeed | int | `32` | Cap applied after a downgrade, and to blacklisted IPs, Mb/s (LIMIT_SPEED). |
| hbbr.config.singleBandwidth | int | `128` | Per-connection bandwidth cap, Mb/s (SINGLE_BANDWIDTH). |
| hbbr.config.totalBandwidth | int | `1024` | Aggregate bandwidth cap, Mb/s (TOTAL_BANDWIDTH). |
| hbbr.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| hbbr.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| hbbr.containerSecurityContext.readOnlyRootFilesystem | bool | `true` |  |
| hbbr.dataDir | string | `"/data"` | Working directory. hbbr writes nothing here when a key is supplied explicitly, which is what this chart always does. |
| hbbr.enabled | bool | `true` | Deploy the hbbr role: the relay used when peers cannot connect directly. |
| hbbr.extraArgs | list | `[]` |  |
| hbbr.extraEnv | list | `[]` |  |
| hbbr.hostNetwork | bool | `false` |  |
| hbbr.key.existingSecret | string | `""` |  |
| hbbr.key.existingSecretKey | string | `"id_ed25519.pub"` |  |
| hbbr.key.publicKey | string | `""` | For a relay-only release (`hbbs.enabled: false`), supply the installation's public key here, or name a Secret below. Within a release that also runs hbbs, leave both empty and the chart wires up the generated key automatically. |
| hbbr.key.validation | bool | `true` | Reject clients that do not present this installation's public key. Upstream defaults this off, which makes the relay usable by anyone who knows its address — with default limits of 128 Mb/s per connection and 1024 Mb/s aggregate. hbbr only ever holds the PUBLIC key: it compares an opaque string and performs no signature verification or decryption, so the private key never leaves the hbbs pod. |
| hbbr.lists.blacklist | list | `[]` | Bandwidth-limited IPs, one per line. |
| hbbr.lists.blocklist | list | `[]` | Refused IPs, one per line. |
| hbbr.lists.enabled | bool | `false` | Mount `blacklist.txt` and `blocklist.txt` from a ConfigMap. hbbr reads these once at startup from its working directory, and edits made through its runtime console are in-memory only — so a ConfigMap is the only way to make them survive a restart. |
| hbbr.livenessProbe.enabled | bool | `true` |  |
| hbbr.livenessProbe.failureThreshold | int | `6` |  |
| hbbr.livenessProbe.initialDelaySeconds | int | `10` |  |
| hbbr.livenessProbe.periodSeconds | int | `20` |  |
| hbbr.livenessProbe.tcpSocket | bool | `true` |  |
| hbbr.livenessProbe.timeoutSeconds | int | `3` |  |
| hbbr.nodeSelector | object | `{}` |  |
| hbbr.podAnnotations | object | `{}` |  |
| hbbr.podLabels | object | `{}` |  |
| hbbr.podSecurityContext.fsGroup | int | `65534` |  |
| hbbr.podSecurityContext.runAsGroup | int | `65534` |  |
| hbbr.podSecurityContext.runAsNonRoot | bool | `true` |  |
| hbbr.podSecurityContext.runAsUser | int | `65534` |  |
| hbbr.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| hbbr.port | int | `21117` | Base port. The WebSocket transport listens on `port + 2`. Passed with `-p`, never via the PORT environment variable, which upstream interprets as `PORT + 1`. |
| hbbr.priorityClassName | string | `""` |  |
| hbbr.readinessProbe.enabled | bool | `true` |  |
| hbbr.readinessProbe.failureThreshold | int | `3` |  |
| hbbr.readinessProbe.initialDelaySeconds | int | `5` |  |
| hbbr.readinessProbe.periodSeconds | int | `10` |  |
| hbbr.readinessProbe.tcpSocket | bool | `true` |  |
| hbbr.readinessProbe.timeoutSeconds | int | `3` |  |
| hbbr.replicaCount | int | `1` | hbbr pairs the two peers of a session by UUID inside a single process, so two replicas behind one Service silently fail to pair whenever the peers land on different pods. `sessionAffinity` does not help — the two peers have different client IPs by definition. Add relay capacity with additional relay-only releases at distinct addresses, listed in `hbbs.config.relayServers`. |
| hbbr.resources | object | `{}` |  |
| hbbr.service.annotations | object | `{}` |  |
| hbbr.service.externalTrafficPolicy | string | `"Local"` |  |
| hbbr.service.loadBalancerClass | string | `""` |  |
| hbbr.service.loadBalancerIP | string | `""` |  |
| hbbr.service.nodePorts.main | string | `nil` |  |
| hbbr.service.nodePorts.websocket | string | `nil` |  |
| hbbr.service.type | string | `"LoadBalancer"` |  |
| hbbr.tolerations | list | `[]` |  |
| hbbr.topologySpreadConstraints | list | `[]` |  |
| hbbr.webClient.enabled | bool | `false` | Expose the WebSocket relay on `port + 2` (21119 by default). Carries the same unvalidated-header risk as `hbbs.webClient.enabled`. |
| hbbs.affinity | object | `{}` |  |
| hbbs.config.alwaysUseRelay | bool | `false` | Force all sessions through the relay, disabling hole punching (ALWAYS_USE_RELAY). |
| hbbs.config.dbUrl | string | `""` | SQLite path (DB_URL). Defaults to `db_v2.sqlite3` inside the working directory, which is the persistent volume. |
| hbbs.config.relayServers | list | `[]` | Explicit relay addresses passed to `-r`, as `host` or `host:port`. Leave empty unless the relay is not reachable at `<ID server host>:<port + 1>`. An empty list is correct, not incomplete: hbbs advertises no relay address at all, and the client derives one from the ID server address its own user typed. Set this when running relay-only releases — multiple entries also enable hbbs's round-robin and its relay health check, which is otherwise never started. |
| hbbs.config.rmem | int | `0` | UDP receive buffer in bytes (RMEM). Raising this also requires raising `net.core.rmem_max` on the node, which this chart does not do. |
| hbbs.config.selfTest | bool | `true` | hbbs pings its own UDP listener once a second for the life of the process and calls `exit(1)` if replies stop for 12 seconds. It targets loopback, never the external address, so it is safe behind a LoadBalancer and is left enabled. Setting this to false emits `TEST_HBBS=no`. |
| hbbs.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| hbbs.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| hbbs.containerSecurityContext.readOnlyRootFilesystem | bool | `true` |  |
| hbbs.dataDir | string | `"/data"` | The key pair and the SQLite database live here, and it is the container's working directory — both binaries write relative to their CWD, which is what makes a read-only root filesystem possible. |
| hbbs.enabled | bool | `true` | Deploy the hbbs role: ID registration, rendezvous and hole punching. Disable it to install a relay-only release (see `hbbr.key`). |
| hbbs.extraArgs | list | `[]` |  |
| hbbs.extraEnv | list | `[]` |  |
| hbbs.hostNetwork | bool | `false` | Run with the host's network namespace instead of a LoadBalancer. This is what upstream's own documentation recommends and it guarantees the real source IP, at the cost of pinning the pod to a node and claiming ports 21115-21119 across the cluster. |
| hbbs.livenessProbe.enabled | bool | `true` |  |
| hbbs.livenessProbe.failureThreshold | int | `6` | Deliberately tolerant. This is a single-replica stateful pod, so a false positive is more expensive than a slow restart. hbbs also watchdogs its own UDP path and exits on failure, which catches what a TCP probe cannot see. |
| hbbs.livenessProbe.initialDelaySeconds | int | `10` |  |
| hbbs.livenessProbe.periodSeconds | int | `20` |  |
| hbbs.livenessProbe.tcpSocket | bool | `true` |  |
| hbbs.livenessProbe.timeoutSeconds | int | `3` |  |
| hbbs.nodeSelector | object | `{}` |  |
| hbbs.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| hbbs.persistence.annotations | object | `{}` |  |
| hbbs.persistence.enabled | bool | `true` |  |
| hbbs.persistence.existingClaim | string | `""` | Use a volume you already have. The reason this chart uses a plain PVC rather than a StatefulSet `volumeClaimTemplate`: a claim template names PVCs by ordinal and cannot be pointed at an existing volume, which would block both migration and restore from backup. |
| hbbs.persistence.retain | bool | `true` | Keep the PVC on `helm uninstall`. |
| hbbs.persistence.size | string | `"1Gi"` |  |
| hbbs.persistence.storageClass | string | `""` |  |
| hbbs.podAnnotations | object | `{}` |  |
| hbbs.podLabels | object | `{}` |  |
| hbbs.podSecurityContext.fsGroup | int | `65534` |  |
| hbbs.podSecurityContext.runAsGroup | int | `65534` |  |
| hbbs.podSecurityContext.runAsNonRoot | bool | `true` |  |
| hbbs.podSecurityContext.runAsUser | int | `65534` |  |
| hbbs.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| hbbs.port | int | `21116` | Base port. hbbs derives its other ports from this one in code: the NAT-type test listens on `port - 1` and the WebSocket transport on `port + 2`. Changing it is rarely a good idea — clients derive the relay address as `<their ID server host>:<its port + 1>`, so a non-default port here makes them derive the WebSocket relay port instead of the relay port. See docs/adr/0005-empty-relay-servers-default.md. |
| hbbs.priorityClassName | string | `""` |  |
| hbbs.readinessProbe.enabled | bool | `true` |  |
| hbbs.readinessProbe.failureThreshold | int | `3` |  |
| hbbs.readinessProbe.initialDelaySeconds | int | `5` |  |
| hbbs.readinessProbe.periodSeconds | int | `10` |  |
| hbbs.readinessProbe.tcpSocket | bool | `true` |  |
| hbbs.readinessProbe.timeoutSeconds | int | `3` |  |
| hbbs.resources | object | `{}` | No defaults on purpose. Traffic profiles for a rendezvous server vary by orders of magnitude between a five-device homelab and a fleet, and a wrong default is worse than none. |
| hbbs.service.annotations | object | `{}` | To place hbbs and hbbr on a single address with MetalLB, set the same `metallb.universe.tf/allow-shared-ip` value on both Services. They have no overlapping ports, so sharing is safe. Not the default, because the annotation is MetalLB-specific and would break the chart on other load balancer implementations. |
| hbbs.service.externalTrafficPolicy | string | `"Local"` | Must stay `Local`. `Cluster` rewrites the source address and breaks hole punching in a way that still looks like a working install.  With `NodePort`, `Local` also means only the node currently running the pod answers on the node port. Many external port forwarders and simple L4 balancers target a fixed address and cannot see Endpoints, so they will point at a black hole whenever the pod moves. Pin the pod with `nodeSelector` and target the same node. See docs/exposure.md. |
| hbbs.service.loadBalancerClass | string | `""` |  |
| hbbs.service.loadBalancerIP | string | `""` |  |
| hbbs.service.nodePorts.main | string | `nil` |  |
| hbbs.service.nodePorts.natTest | string | `nil` |  |
| hbbs.service.nodePorts.websocket | string | `nil` |  |
| hbbs.service.type | string | `"LoadBalancer"` | `LoadBalancer` preserves the client source IP when paired with `externalTrafficPolicy: Local`, which is a correctness requirement rather than a preference: hbbs stores the observed packet source as the peer's NAT endpoint and hands it to the other peer to dial. Behind any SNAT-ing hop, every session silently falls back through the relay. |
| hbbs.tolerations | list | `[]` |  |
| hbbs.topologySpreadConstraints | list | `[]` |  |
| hbbs.webClient.enabled | bool | `false` | Expose the WebSocket transport on `port + 2` (21118 by default). Off by default: this port accepts `X-Real-IP` and `X-Forwarded-For` without validation and overwrites the peer's address with whatever the header claims, so anyone who can reach it directly can present themselves as any source IP. Only enable it behind a proxy that OVERWRITES those headers rather than passing them through. This chart ships no Ingress; see docs/adr/0006. |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.registry | string | `"docker.io"` | Registry for the RustDesk server image. |
| image.repository | string | `"rustdesk/rustdesk-server"` | The "classic" upstream image. It is built `FROM scratch` and holds only the `hbbs` and `hbbr` binaries — there is no shell, so `kubectl exec` and `kubectl cp` do not work against these containers and `exec` probes are impossible. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. Avoid `latest`: this chart is published to strangers, and a floating tag ships them upstream changes that never passed CI here. |
| imagePullSecrets | list | `[]` | Image pull secrets applied to every pod in this release. |
| key.existingSecret | string | `""` | Use a key pair you already have instead of generating one. Set this to the name of a Secret containing `id_ed25519` and `id_ed25519.pub`. This is the migration path from docker-compose or another chart — see docs/migration.md. When set, the chart neither generates a key nor needs RBAC to create a Secret. |
| key.privateKeyKey | string | `"id_ed25519"` | Key within `existingSecret` holding the base64 private key. |
| key.publicKeyKey | string | `"id_ed25519.pub"` | Key within `existingSecret` holding the base64 public key. |
| key.secretName | string | `""` | Name of the Secret holding the key pair. Defaults to `<fullname>-key`. This Secret is the source of truth: the persistent volume is only a cache of it. The chart does not template this Secret — an initContainer creates it — so Helm never owns an object whose contents it does not manage, and the key survives `helm uninstall` without a retention annotation. |
| kubectlImage.pullPolicy | string | `"IfNotPresent"` |  |
| kubectlImage.registry | string | `"registry.k8s.io"` | The Kubernetes project's own kubectl image, used to read and write the key Secret. |
| kubectlImage.repository | string | `"kubectl"` |  |
| kubectlImage.tag | string | `"v1.31.4"` |  |
| nameOverride | string | `""` | Overrides the chart name used in resource names. |
| networkPolicy.enabled | bool | `false` | These pods are deliberately reachable from the entire internet, so the ingress half of a policy restricts very little. The useful half is egress. Off by default, but worth enabling under a default-deny policy. |
| networkPolicy.extraEgress | list | `[]` | Additional egress rules, appended to the DNS and Kubernetes API rules the chart already emits. |
| rbac.create | bool | `true` | Create the Role and RoleBinding that let the initContainers read and create the key Secret. Only needed when the chart generates the key; set to false alongside `key.existingSecret`. Note that RBAC cannot scope `create` to a single resource name, so the Role grants `create` on Secrets in this namespace. |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the key-provisioning initContainers. |
| serviceAccount.name | string | `""` | Use an existing ServiceAccount instead. Ignored when `create` is true. |
| tests.enabled | bool | `true` | Ship a `helm test` Pod that asserts the Services have endpoints and the key Secret exists and is non-empty. It runs inside the cluster, so it cannot exercise the LoadBalancer path, `externalTrafficPolicy`, or UDP. |
| utilsImage.pullPolicy | string | `"IfNotPresent"` |  |
| utilsImage.registry | string | `"docker.io"` |  |
| utilsImage.repository | string | `"rustdesk/rustdesk-server-s6"` | The upstream s6 image. Used because it is the only official image that carries `rustdesk-utils` and a busybox shell. Its supervisor is never started. |
| utilsImage.tag | string | `""` | Defaults to the chart's appVersion, so it always matches the server image. |

## Contributing

`helm lint`, `kubeconform`, and a real install on k3d run in CI. Note that CI cannot exercise
the default LoadBalancer path — k3d has no MetalLB — so changes to Service templates need
testing on a real cluster.

## Licence

Apache-2.0. This chart is not a derivative work of the RustDesk server; it references
its images.
