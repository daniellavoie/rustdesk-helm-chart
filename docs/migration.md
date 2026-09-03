# Migrating an existing installation

The thing that makes people put off moving a RustDesk server is that getting it wrong
disconnects every enrolled client. It does not have to: the key pair is the only piece of
state that matters for client continuity, and it is portable.

Two things are worth carrying over:

- **`id_ed25519` and `id_ed25519.pub`** — the installation's identity. Clients pin the public
  half at enrollment. Bring this and nobody has to touch a client.
- **`db_v2.sqlite3`** — the peer table, mapping IDs to public keys and device info. Losing it
  is survivable; clients re-register. Bring it to keep device names and history.

## Step 1: get the existing key pair

**From docker-compose or a bare install** — the files sit in the server's working directory
(`/root` in the classic image, `/data` in the s6 image, `/var/lib/rustdesk-server` under
systemd):

```bash
docker cp <hbbs-container>:/root/id_ed25519 .
docker cp <hbbs-container>:/root/id_ed25519.pub .
```

**From another Helm chart** — most community charts let hbbs generate the key onto its
volume, and several default to an `emptyDir`. Copy it out of the running pod, or mount the
PVC into a temporary pod if the image has no shell.

Verify the pair before you rely on it:

```bash
docker run --rm -v "$PWD:/k:ro" --entrypoint rustdesk-utils \
  rustdesk/rustdesk-server-s6:1.1.16 validatekeypair "$(cat id_ed25519.pub)" "$(cat id_ed25519)"
```

## Step 2: create the Secret

Trailing newlines break relay authentication — the comparison is byte-exact and does no
trimming. `--from-file` preserves file contents exactly, so prefer it over `--from-literal`,
and strip any newline your copy introduced:

```bash
printf '%s' "$(cat id_ed25519)"     > id_ed25519
printf '%s' "$(cat id_ed25519.pub)" > id_ed25519.pub

kubectl create secret generic rustdesk-key \
  --from-file=id_ed25519=id_ed25519 \
  --from-file=id_ed25519.pub=id_ed25519.pub
```

## Step 3: install pointing at it

```yaml
key:
  existingSecret: rustdesk-key
# No key generation happens, so the chart needs neither the ServiceAccount nor RBAC.
rbac:
  create: false
serviceAccount:
  create: false
```

```bash
helm install rustdesk oci://ghcr.io/daniellavoie/helm-charts/rustdesk-server -f values.yaml
```

## Step 4 (optional): bring the database

Create the PVC and copy `db_v2.sqlite3` into it before first start, then point the chart at
it with `hbbs.persistence.existingClaim`. SQLite runs in WAL mode, so copy
`db_v2.sqlite3-wal` and `db_v2.sqlite3-shm` alongside the database — with the server stopped,
or the copy may be inconsistent.

## Step 5: cut over

Point DNS or your port forwards at the new Services. Because clients are configured with a
hostname and a key, and both are unchanged, they reconnect on their own.

Keep the old server reachable until you have confirmed a real session — both a direct one and
a relayed one. The relay path fails independently of the rendezvous path, so a working direct
connection does not prove the relay works.

## What is not migrated

Values files from other charts are not convertible; the structures do not correspond. Read
`values.yaml` and write a new one. It is a short file.
