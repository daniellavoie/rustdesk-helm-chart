# An initContainer generates the key pair and publishes it as a Secret

The key pair identifies the installation; clients pin its public half at enrollment, so losing
or rotating it disconnects every enrolled client. Three of the community charts default to an
`emptyDir`, which silently rotates the key on every pod restart. This is the gap upstream
maintainers named when declining to bless a chart.

An initContainer in the hbbs pod, running the s6 image's `rustdesk-utils genkeypair`, generates
the pair when one is not already present, writes it to the persistent volume, and publishes it
to a Secret. hbbs then simply loads it. A user-supplied Secret overrides generation entirely.

## Considered options

**Generating the pair in Helm templates is not possible.** The on-disk format is base64 of a
64-byte libsodium ed25519 secret key, which is not what `genPrivateKey "ed25519"` emits.
Recording this so it is not re-attempted — the initContainer is the workaround, not an
oversight.

**Letting hbbs auto-generate and extracting the key afterwards with a post-install hook Job**
was rejected on two counts: the volume is ReadWriteOnce, so the Job would need `podAffinity`
onto the hbbs pod to mount it at all, and on first install the hook races hbbs's own generation.
The initContainer shares the pod, so it has neither problem.

## Consequences

- The chart requires a ServiceAccount, Role and RoleBinding granting create/patch on a single
  Secret. This is a real privilege the chart asks for, and restrictive cluster policies will
  flag it.
- The chart depends on two upstream images rather than one — but the second is the official s6
  image, so this adds no third-party supply chain.

## The Secret is authoritative

The Secret is the source of truth and the volume is a materialized cache. If the volume is
lost, the key is recovered from the Secret; if the Secret were merely a published copy, losing
the volume would disconnect every enrolled client permanently. This also puts the key in an
object that backup, GitOps and sealed-secret tooling already understands.

The chart does not template the Secret — the initContainer creates it — so Helm never owns an
object whose contents it does not manage, and the key survives `helm uninstall` without a
retention annotation.

Rotation is never automatic. Replacing the key requires deleting the Secret explicitly, an
operation that disconnects every enrolled client.
