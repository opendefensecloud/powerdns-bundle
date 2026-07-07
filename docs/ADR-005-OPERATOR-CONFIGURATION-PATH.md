# ADR-005 — Operator as Primary Configuration Path

**Status:** Accepted

## Context

DNS configuration for the PowerDNS Authoritative Server can be performed via three paths:

1. **Kubernetes CRDs** processed by the PowerDNS Operator (Kubernetes-native, GitOps-compatible).
2. **PowerDNS HTTP API** on port 8081 (direct, bypasses Kubernetes).
3. **Web UI** (PowerDNS-Admin), which also drives the HTTP API on port 8081.

The PowerDNS Operator (OSS: [powerdns-operator/PowerDNS-Operator](https://github.com/powerdns-operator/PowerDNS-Operator)) reconciles CRDs against the Auth API exclusively on Kubernetes watch events. It does **not** perform periodic drift detection — if the Auth state is modified outside of Kubernetes (e.g., directly via API or web UI), the Operator will not detect or correct the divergence until the next CRD event.

## Decision

The Operator is the **primary and authoritative configuration path** for all regular DNS changes. All zone and record management is performed through `Zone`, `ClusterZone`, `RRset`, and `ClusterRRset` CRDs.

The HTTP API on port 8081 remains accessible to preserve the option of integrating a web UI at a later stage. However, concurrent direct API access must be governed by an operational procedure to prevent state drift.

## Consequences

- All DNS configuration is GitOps-compatible and auditable via the Kubernetes API (kubectl, audit logs).
- The Operator translates desired CRD state into live PowerDNS configuration and updates CRD status fields on each reconciliation cycle.
- Direct manipulation of the Auth API (bypassing CRDs) will not be reflected back to Kubernetes — drift will persist until the next CRD event triggers reconciliation.
- If a web UI is integrated, the operational concept must define whether concurrent access is permitted and how drift is managed (e.g., UI used read-only, or temporal separation enforced).
- A separate Operator instance is required per Auth server instance; this is a constraint of the upstream OSS Operator.
