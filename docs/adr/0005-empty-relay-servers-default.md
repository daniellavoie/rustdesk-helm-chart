# hbbs ships with no relay address configured, on purpose

`hbbs.relayServers` (`-r`) defaults to empty, and that is correct rather than incomplete.

hbbs never advertises a relay address: with `-r` unset, `get_relay_server()` returns the empty
string and sends it on the wire. The *controlled client* fills it in, deriving
`increase_port(self.host, 1)` from the ID-server address **its own user typed** — not from
anything the server reports. That derived address then passes back through hbbs untouched. So a
client configured with `H:21116` relays via `H:21117`, and the fact that a NAT forwards those
two ports to two different internal hosts is invisible to both the client and hbbs. They never
communicate on this path.

Deriving a relay address server-side — from the Service's `loadBalancerIP`, for instance — is
therefore not merely wrong behind NAT, where that address is an RFC1918 LAN IP, but the wrong
mechanism entirely.

## Consequences

- The derivation silently breaks for clients configured with a non-default ID-server port:
  `H:21118` derives `H:21119`, which is the WebSocket relay port, not the relay port.
- hbbr liveness is never checked. hbbs only spawns its relay health-check task when the relay
  list holds more than one entry, so a dead relay surfaces as a client-side connection failure
  and never as a server-side failover.
- An explicit `-r` remains necessary for a relay on a different host or port, and for multiple
  relays.
