# ADR-002 — LMDB as Primary Data Store

**Status:** Accepted

## Context

The DNS Authoritative Server requires a data store for zone data. The solution targets resource-constrained environments where running a dedicated database server (PostgreSQL, MySQL, etc.) would impose unacceptable overhead. The data store must support the stateless-optimised approach and be compatible with air-gapped deployments. It must also be natively supported by Lightning Stream for LMDB snapshot replication.

## Decision

Use LMDB as the embedded data store for zone data in the PowerDNS Authoritative Server. LMDB is backed by a Persistent Volume Claim (PVC) in each pod.

## Rationale

| Backend | Assessment | Exclusion reason |
|---|---|---|
| **LMDB** | ✅ Selected | No separate server, zero network latency, native Lightning Stream support, OS page cache efficiency |
| BIND zone files | ❌ | No HTTP API — the Operator cannot write records via the Auth management API |
| SQLite | ❌ | No Lightning Stream support; lock contention under concurrent read/write |
| PostgreSQL / MySQL | ❌ | External stateful dependency — contradicts the stateless-optimised requirement; requires separate pod, PVC, and backup strategy |

LMDB is memory-mapped and embedded directly into the PowerDNS process: reads are zero-copy from the OS page cache, no network hop, and no additional RAM beyond what the OS already uses for page caching. The single-writer model is sufficient for the write patterns of DNS zone management.

| Property | LMDB | PostgreSQL |
|---|---|---|
| Separate process | No (linked in) | Yes (own pod) |
| Network latency per lookup | 0 ms (in-process) | 0.5–2 ms (TCP) |
| Additional RAM | ~0 MB (uses OS page cache) | 100–300 MB (shared_buffers etc.) |
| PersistentVolumeClaim | Optional (emptyDir possible) | Required |
| Air-gap effort | No additional image | Additional image + init |
| Lightning Stream compatibility | Native (from Auth 4.8) | Not supported |

## Consequences

- No external database server is required, significantly reducing resource consumption and operational complexity.
- The stateless-optimised design goal is supported: mutable state is replicated externally via Lightning Stream (see [ADR-003](ADR-003-LIGHTNINGSTREAM-MINIO-REPLICATION.md)).
- No SQL access to zone data. Configuration changes only via Operator/API, not via database tools.
