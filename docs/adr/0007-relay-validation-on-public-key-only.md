# The relay validates clients by default, holding only the public key

hbbr's `KEY` defaults to empty upstream, which disables relay validation entirely — the relay
accepts anyone who knows its address. With default bandwidth limits of 128 Mb/s per connection
and 1024 Mb/s aggregate, an unvalidated relay on a public address is a free proxy. Upstream's
default is a single-host convenience, not a security posture, so this chart enables validation
by default.

The private key never leaves the hbbs pod. hbbr's `get_server_sk` normalizes any accepted input
down to the base64 *public* key, and validation is a plain string comparison against the
`licence_key` field that clients send — which is itself the public key. hbbr performs no
signature verification and no decryption; it is a blind byte pump, and session encryption is
end-to-end between the two clients. Only hbbs needs the private half, to sign the `IdPk` it
returns.

So hbbr receives only `id_ed25519.pub`, and a relay-only release in another cluster needs only
the public key distributed to it.

## Consequences

- **hbbr must never be started with `-k _` or `-k -` in a split deployment.** When `id_ed25519`
  is absent, that path fabricates a fresh keypair and overwrites `id_ed25519.pub`, silently
  desyncing from hbbs and corrupting hbbs's key material on any shared volume. The chart passes
  the public-key string explicitly.
- **The value must be byte-exact.** The comparison does not trim, so a trailing newline in a
  rendered Secret breaks authentication.
- A key mismatch fails only relayed sessions; direct connections keep working. The single piece
  of evidence is one warn line, `Relay authentication failed from <ip> - invalid key`. Users will
  report this as "works on my LAN, fails from outside".
