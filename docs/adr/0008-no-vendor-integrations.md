# The chart integrates with no specific load balancer or port forwarder

Exposing this server correctly depends heavily on the surrounding network: which load balancer
implementation, which router or port-forward controller, which annotations each of those reads.
It is tempting to generate those integrations from the chart — the resources are small, and it
would make the chart much pleasanter in the environment it was developed against.

We do not. The chart exposes generic `service.annotations`, `service.nodePorts`, `nodeSelector`
and `affinity`, and nothing else. Users drive their own infrastructure through those, or create
its resources separately.

## Considered options

Generating the custom resources for a specific port-forward controller was considered and
rejected. It would bind a chart published to strangers to a `v1alpha1` CRD from an unreleased,
single-maintainer project — coupling the chart's correctness to something neither its users nor
its maintainer control, and reading as an endorsement of that dependency. The same argument
applies to every load balancer's proprietary annotations: MetalLB's `allow-shared-ip` is
documented, not templated.

## Consequences

- Documentation carries the burden instead, and stays vendor-neutral: `docs/exposure.md`
  describes the failure modes generically, because the important one — a forwarder that cannot
  see Endpoints pointing at a node with no pod — is common to most of them, not specific to any.
- The chart can only ever see half of a NodePort arrangement. It knows whether a pod is pinned;
  it cannot know what an opaque annotation tells some controller to target. That is why the
  mismatch is a warning in `NOTES.txt` rather than a hard failure: failing on half the
  information would block correct configurations, including single-node clusters where pinning
  is meaningless.
