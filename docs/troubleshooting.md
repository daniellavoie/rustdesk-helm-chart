# Troubleshooting, by symptom

Almost every failure mode of a self-hosted RustDesk server looks like partial success. The
server starts, clients connect, and something is quietly wrong. This guide is keyed by what
you actually observe.

---

## "It works, but every session is slow / all traffic goes through the relay"

The most common misconfiguration, and the one that looks healthiest.

hbbs records the **observed source address** of a client's UDP packet as that peer's public
NAT endpoint, and hands it to the other peer to dial for hole punching. If anything between
the client and the pod rewrites the source address, every peer appears to come from the same
address, hole punching hands out an unroutable endpoint, and every session falls back to the
relay. Nothing errors.

Check, in order:

1. `kubectl get svc <release>-hbbs -o jsonpath='{.spec.externalTrafficPolicy}'` — must be
   `Local`. `Cluster` SNATs through kube-proxy and breaks this.
2. Your load balancer must not SNAT. MetalLB in L2 mode with `Local` preserves the source;
   many cloud L4 balancers do too, but check.
3. Confirm what hbbs actually sees: `kubectl logs <hbbs-pod> | head -50`. If every peer
   registers from the same address (a node IP, or something like `10.42.0.1`), the source is
   being rewritten.
4. If you cannot make your platform preserve the source address, set `hbbs.hostNetwork: true`
   and `hbbr.hostNetwork: true`. This is what upstream's own documentation recommends.

## "Clients that used to work all stopped connecting at once"

The key pair changed. Clients pin the public key at enrollment, so a new key invalidates
every one of them.

```
kubectl get secret <release>-key -o jsonpath='{.data.id_ed25519\.pub}' | base64 -d; echo
```

Compare that to the key configured in a client. If they differ, the installation's identity
changed. Restore the old Secret from backup if you have it — the fix is to put the original
key back, not to re-enroll every client.

This chart is designed to make that impossible under normal operation: the Secret is the
source of truth, the volume is only a cache, and the Secret is not owned by Helm so it
survives `helm uninstall`. If the key changed anyway, someone deleted the Secret.

## "Works on my LAN, fails from outside" / "direct connections work, relayed ones don't"

The relay is rejecting clients, or is unreachable. These fail independently of hbbs, so
direct connections keep working and only fallback sessions break.

1. Look for this in the relay log — it is the *only* evidence of a key mismatch:
   ```
   kubectl logs deploy/<release>-hbbr | grep "Relay authentication failed"
   ```
   `Relay authentication failed from <ip> - invalid key` means hbbr's `KEY` does not match
   the public key clients are sending. In a relay-only release, check `hbbr.key.publicKey`
   against the hbbs installation's `id_ed25519.pub`. A **trailing newline** is a common
   cause: the comparison is byte-exact and does no trimming.
2. If there is no such line, clients are not reaching the relay at all. Confirm port 21117
   is forwarded to hbbr's address. Remember the relay address is derived *client-side* as
   `<the ID server host the user typed>:<its port + 1>` — see below.

## "Clients show offline / cannot register at all"

Port 21116 **UDP** is not reaching the pod. It carries registration and heartbeat; TCP alone
is not enough and TCP is what most connectivity tests check.

```
nc -zvu <your public host> 21116
kubectl get svc <release>-hbbs -o yaml | grep -A3 'protocol: UDP'
```

On Kubernetes older than 1.26, a Service with both TCP and UDP required a feature gate and
the UDP port was silently dropped. This chart declares `kubeVersion: ">=1.26.0-0"` to make
that an install-time error instead.

## "The hbbs pod restarts periodically with `Failed to run hbbs test`"

Expected behaviour, not a chart bug. hbbs pings its own UDP listener once a second for the
life of the process, and calls `exit(1)` if replies stop for 12 seconds. It is a permanent
watchdog, not a startup check, so this can fire hours into a healthy run — it means the
pod's own UDP loopback path wedged, and restarting is the correct response.

It targets loopback, never your external address, so it is unrelated to NAT or hairpinning.
Set `hbbs.config.selfTest: false` to disable it, but prefer finding out why UDP stalled.

## "The hbbr pod is stuck in CreateContainerConfigError"

It is waiting for the key Secret, which is deliberate. hbbr takes its public key from a
Secret reference that is **not** marked optional, so a missing Secret holds the pod rather
than starting a relay open to anyone on the internet.

On a first install this resolves itself once the key hook completes. If it persists:

- Co-installed with hbbs: check the `pre-install` hook Job ran — `kubectl get job
  <release>-key-init`. If it failed, `kubectl logs job/<release>-key-init`.
- Relay-only release (`hbbs.enabled: false`): you must supply `hbbr.key.publicKey` or
  `hbbr.key.existingSecret` yourself.

## "Relayed sessions work for some clients and not others"

Clients derive the relay address from **their own** configured ID server string, so clients
configured differently derive different relay addresses. A client configured with an internal
IP will hand its peer an internal relay address that the peer cannot reach.

Either configure every client with the same public hostname, or set
`hbbs.config.relayServers` explicitly to pin the address server-side.

## "I changed hbbs.port and now relaying is broken"

Clients compute the relay address as `<ID server host>:<port + 1>`. With the default 21116
that gives 21117, which is the relay. Set the ID server port to 21118 and clients derive
21119 — the *WebSocket* relay port, not the relay port.

Change the port only alongside an explicit `hbbs.config.relayServers`.

## "Install fails: chart requires kubeVersion"

Your cluster is below 1.26, or reports a version Helm cannot parse. See the UDP section
above for why the floor exists. If your provider misreports its version, `helm install
--kube-version 1.31.0` overrides the check — but confirm mixed-protocol LoadBalancer
Services actually work there first, or you will hit the silent-UDP failure.

## "The public key contains a `/` and will not paste into a client"

The server's own generator retries until the base64 public key contains neither `/` nor `:`,
because those characters break the config strings the key is pasted into. Roughly half of
raw keys hit this. This chart reproduces that filter when generating.

If you imported a key from elsewhere and it contains those characters, it was generated by
`rustdesk-utils genkeypair` directly, which does not filter. Generate a new pair — but note
that changing the key disconnects every enrolled client.
