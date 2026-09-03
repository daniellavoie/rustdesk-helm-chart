# The web-client ports are off by default and the chart ships no Ingress

Ports 21118 (hbbs) and 21119 (hbbr) carry the WebSocket transport used by the RustDesk web
client. Both accept `X-Real-IP` and `X-Forwarded-For` **without validation** and overwrite the
peer's address with whatever the header claims, so anyone who can reach those ports directly can
present themselves as any source IP. Upstream's guidance is to keep them closed unless the web
client is needed, and to expose them only behind a proxy that *overwrites* those headers rather
than forwarding them.

They are therefore disabled by default, behind an explicit flag, with the requirement stated in
the values file rather than buried in a README.

The chart ships **no Ingress template at all**. An Ingress cannot carry ports 21115, 21116 or
21117 — those are raw TCP and UDP — so it could only ever serve the off-by-default web-client
ports, and their safety depends entirely on per-controller header handling that this chart
cannot verify. Shipping a template we cannot prove sanitizes headers on the user's ingress
controller means shipping a spoofing hole under our name. Documented nginx and Traefik
configurations are the deliverable instead.

Revisit if per-controller header sanitization can be tested in CI.
