# ADR-003 — lightningstream + Garage for LMDB Replication

**Status:** Accepted

## Context

LMDB data stored on a PVC is lost if a pod is deleted or rescheduled. A replication and backup concept is required for fault tolerance and data availability across pod restarts and for multi-instance operation. The solution must remain lightweight, Kubernetes-native, and suitable for air-gapped deployments.

Lightning Stream together with an S3-compatible object store is the established replication mechanism for PowerDNS + LMDB. The original S3 store candidate was MinIO. MinIO entered maintenance mode in December 2025 and was officially archived in February 2026, making it unsuitable as a long-term dependency.

## Decision

Use **lightningstream** as a sidecar container alongside each PowerDNS Authoritative pod to continuously replicate LMDB snapshots to a **Garage** cluster deployed within the Kubernetes cluster.

- lightningstream runs in the same pod as the PowerDNS process with direct access to the LMDB volume.
- Garage provides S3-compatible object storage bundled in the OCM package (air-gap compatible).
- On pod startup, lightningstream restores the latest LMDB snapshot from Garage before the PowerDNS process serves queries.

## Rationale

| S3 option | License | Assessment |
|---|---|---|
| **Garage** | AGPLv3 | ✅ Selected — lightweight (Rust, single binary), community-driven (Deuxfleurs collective, no upsell risk), S3-compatible, edge-suitable |
| SeaweedFS | Apache 2.0 | ⚠️ Alternative for scaling needs — larger feature set, somewhat heavier |
| MinIO | AGPLv3 | ❌ Archived since February 2026 — no further updates or security fixes |

## Consequences

- Pod restarts and rescheduling are non-destructive: zone data is restored from the Garage snapshot within the pod startup sequence.
- No heavyweight database cluster is required for replication.
- Garage is Kubernetes-native and bundled in the OCM package, maintaining air-gap compatibility.
- lightningstream introduces an additional sidecar container per pod; resource budgets must account for it.
- The AGPLv3 license of Garage requires a compatibility review with the overall project licensing.
- The Garage cluster is a shared dependency across DNS instances in multi-instance deployments and must be sized accordingly.
- For single-instance deployments, the S3 store is optional — see [ADR-006](ADR-006-S3-FOR-MULTI-INSTANCE.md).
