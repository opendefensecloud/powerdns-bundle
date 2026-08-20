# ADR-001 — PowerDNS Component Family

**Status:** Accepted

## Context

The project requires a Software-Defined DNS solution built from Open Source Software building blocks. The solution must strictly separate recursive resolution from authoritative zone serving — a non-negotiable regulatory constraint. DNS zone configuration must be manageable via a Kubernetes Operator without requiring manual file editing or pod restarts. The selected components must be suitable for resource-constrained, air-gapped Kubernetes deployments.

**Evaluated alternatives (in evaluation order):**

| Alternative | Assessment | Reason not selected |
|---|---|---|
| **PowerDNS family** (dnsdist + Recursor + Authoritative) | ✅ Selected | Three purpose-built binaries with enforced separation; zone and record management via HTTP API; no pod restarts required for configuration changes. Maps directly to [PowerDNS Scenario 2: New Situation](https://doc.powerdns.com/authoritative/guides/recursion.html). |
| **CoreDNS + Unbound** | ❌ Not selected | CoreDNS serves as DNS frontend and authoritative server; Unbound provides recursive resolution — giving the same structural separation as the PowerDNS family. However, every zone change requires modifying a syntactically correct and correctly ordered Corefile stored in etcd, followed by a pod restart to apply the new configuration. This makes Operator-driven zone management operationally fragile and incompatible with the declarative, API-driven approach required by the project. |

## Decision

Use the PowerDNS component family as the core DNS building blocks:

- **dnsdist** — DNS frontend, traffic steering, rate limiting, and load balancing.
- **PowerDNS Recursor** — Caching resolver for recursive queries and local zone forwarding.
- **PowerDNS Authoritative Server** — Authoritative name server for internally managed zones.

## Consequences

- The strict Recursor/Authoritative separation required by regulation is architecturally enforced by running them as separate processes in separate Kubernetes Deployments with no shared storage.
- Zone and record changes are applied via the PowerDNS HTTP API (port 8081) without pod restarts — a prerequisite for Operator-driven reconciliation.
- All three PowerDNS components are actively maintained OSS projects under one umbrella, reducing integration complexity.
- The combination maps directly to [PowerDNS Scenario 2: New Situation](https://doc.powerdns.com/authoritative/guides/recursion.html), a well-documented reference architecture.
- Any future substitution of a component by a functional equivalent must demonstrate the same regulatory separation and API-driven configurability, and be documented as a revision of this ADR.
