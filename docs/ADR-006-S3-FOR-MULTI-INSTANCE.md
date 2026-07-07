# ADR-006 — S3 Store only for Multi-Instance Operation

**Status:** Accepted

## Context

Lightning Stream, the LMDB replication sidecar, supports two storage backends:

- **`type: s3`** — Snapshots are written to and read from an S3 bucket. Required when multiple Auth pod instances must share zone data.
- **`type: fs`** — Snapshots are written to a local directory backed by a PVC. Sufficient for a single Auth pod as a backup/recovery mechanism.

Deploying Garage (the selected S3 store, see [ADR-003](ADR-003-LIGHTNINGSTREAM-MINIO-REPLICATION.md)) introduces an additional operational component. For edge deployments with a single Auth pod this overhead provides no functional benefit.

## Decision

The Garage S3 store is **only deployed when multi-instance operation is confirmed**. For single-instance deployments, Lightning Stream uses `type: fs` with a PVC for local snapshot persistence.

## Consequences

- Single-instance deployments (typical edge scenario) have minimal complexity: no S3 pod, no Garage cluster.
- Zone data is still protected against pod restarts via the local PVC snapshot (`type: fs`).
- Scaling to multi-instance requires adding Garage to the OCM package and reconfiguring Lightning Stream to `type: s3` — this is a planned, documented upgrade path.
- KRO ResourceGraphDefinitions must model Garage as a conditional dependency, instantiated only when multi-instance mode is selected.
