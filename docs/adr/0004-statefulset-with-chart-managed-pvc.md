# hbbs is a StatefulSet, but its volume is a chart-managed PVC

hbbs runs exactly one replica and cannot be scaled, so the usual reasons to reach for a
StatefulSet — stable network identity, ordered scale-out — do not apply. We use one anyway for
its stricter single-writer guarantee around the ReadWriteOnce volume, which suits a workload
holding a SQLite database and the key pair.

It does **not** use `volumeClaimTemplates`. The PVC is an ordinary chart-managed resource that
the pod references as a plain volume.

## Consequences

- `existingClaim` is supportable. A `volumeClaimTemplate` derives PVC names from the replica
  ordinal and cannot be pointed at a volume the user already has, which would block both
  migration from another install and restore from a backup.
- The PVC can carry `helm.sh/resource-policy: keep`.
- Upgrades briefly interrupt service, which ReadWriteOnce forces regardless of workload kind.
