# Operations Manual

Day-2 operations guide for the PowerDNS bundle: monitoring, troubleshooting, scaling, backup and recovery, and update procedures.

---

## Contents

1. [Monitoring & Observability](#1-monitoring--observability)
2. [Troubleshooting](#2-troubleshooting)
3. [Scaling](#3-scaling)
4. [Backup & Recovery](#4-backup--recovery)
5. [Update Procedures](#5-update-procedures)
6. [Security Hardening](#6-security-hardening)

---

## 1 Monitoring & Observability

See [OBSERVABILITY.md](OBSERVABILITY.md) for the full reference. Key operational points are summarised here.

### 1.1 Scrape targets

| Component | Service | Port | Path |
|---|---|---|---|
| Recursor | `pdns-recursor` | `8082` | `/metrics` |
| Authoritative Server | `pdns-auth` | `8081` | `/metrics` |
| Operator | `pdns-operator-metrics` | `8080` | `/metrics` |

All Services carry `prometheus.io/scrape: "true"` annotations for annotation-based discovery. For clusters with Prometheus Operator, apply the ServiceMonitor overlay:

```bash
kubectl apply -k deploy/overlays/monitoring
```

### 1.2 Minimum monitoring checklist

Monitor at least:

- DNS query and answer rates by transport and response code
- `SERVFAIL` and other error responses
- Recursor and Authoritative Server latency
- Recursor cache hit rate and cache size
- Operator reconciliation errors and workqueue backlog
- Scrape target availability (Prometheus `up` metric)
- Process CPU, memory, and file-descriptor saturation

### 1.3 Inspecting metrics manually

```bash
kubectl -n dns port-forward service/pdns-recursor 18082:8082
curl -fsS http://127.0.0.1:18082/metrics

kubectl -n dns port-forward service/pdns-auth 18081:8081
curl -fsS http://127.0.0.1:18081/metrics

kubectl -n dns port-forward service/pdns-operator-metrics 18080:8080
curl -fsS http://127.0.0.1:18080/metrics
```

---

## 2 Troubleshooting

### 2.1 DNS resolution failures

**Symptom:** Clients receive `SERVFAIL` or no response.

**Checklist:**

1. **Check the dnsdist pod:** DNS traffic enters through dnsdist. If the dnsdist pod is not running, all resolution fails.
   ```bash
   kubectl -n dns get pod -l app.kubernetes.io/component=dnsdist
   kubectl -n dns logs deployment/dnsdist
   ```

2. **Isolate Recursor vs. Authoritative:** dnsdist forwards recursive queries to the Recursor and may also forward authoritative queries directly to the Auth Server. Test each independently:
   ```bash
   # Recursor (should resolve external names)
   kubectl -n dns port-forward service/pdns-recursor 15353:53
   dig @127.0.0.1 -p 15353 google.com

   # Authoritative Server (should answer for configured zones only)
   kubectl -n dns port-forward service/pdns-auth 15354:53
   dig @127.0.0.1 -p 15354 intern.example.com SOA
   ```

3. **Check Recursor forward-zones:** The Recursor is configured with static forward-zones in its ConfigMap. If the zone list is out of date, queries for a zone that exists in Auth but is not in forward-zones will go to upstream resolvers instead.
   ```bash
   kubectl -n dns get configmap pdns-recursor-config -o yaml
   ```

4. **Check the Authoritative Server:** A zone must exist in both the Auth Server and as a `Zone` or `ClusterZone` CR. Missing records result in `NXDOMAIN`.
   ```bash
   kubectl -n dns get zones
   kubectl -n dns get rrsets
   ```

5. **Inspect Operator reconciliation status:** A zone or record with a non-`Active` `syncStatus` indicates a reconciliation failure. Check the CR status and Operator logs:
   ```bash
   kubectl -n dns describe zone intern.example.com
   kubectl -n dns logs deployment/pdns-operator
   ```

### 2.2 Operator reconciliation failures

**Symptom:** Zone or RRset CR has `syncStatus: Failed` or `syncStatus: Error`.

**Common causes:**

| Cause | Indicator | Resolution |
|---|---|---|
| Auth Server API unreachable | Operator logs show connection refused on port 8081 | Check `pdns-auth` pod and Service |
| Wrong API key | Operator logs show HTTP 401 | Verify the `pdns-operator-api-key` Secret matches the Auth Server's configured key |
| Invalid record data | Operator logs show HTTP 422 | Check the `spec.records` field on the `RRset` CR for syntax errors |
| Zone not found | Operator logs show HTTP 404 on RRset reconcile | Ensure the parent `Zone` CR is reconciled successfully before its `RRset` CRs |

**Read the Operator logs:**

```bash
kubectl -n dns logs deployment/pdns-operator --since=10m
```

### 2.3 LMDB and PVC issues

**Symptom:** Auth pod fails to start or crashes with LMDB-related errors.

**Permission error on startup:**

The `repair-lmdb-permissions` init container runs `chown -R 953:953 /var/lib/powerdns` on every pod start. If this init container fails, the Auth process cannot write to the LMDB files.

```bash
kubectl -n dns describe pod -l app.kubernetes.io/component=pdns-auth
# Look for init container failures
```

**LMDB map size mismatch:**

The Auth Server (`lmdb-map-size`) and the Lightning Stream sidecar (`map_size`) must use the same value. A mismatch causes one process to refuse to open the environment. Check the ConfigMaps:

```bash
kubectl -n dns get configmap pdns-auth-config -o yaml      # lmdb-map-size
kubectl -n dns get configmap lightningstream-config -o yaml # map_size / options.map_size
```

Both must show the same numeric value (default: `1000` MB). For KRO-managed instances, this value comes from the `lmdbMapSizeMB` field on the `PowerDNSInstance` spec — both ConfigMaps, the Auth PVC request, and the Garage layout capacity are derived from it. For statically-managed `deploy/base/` manifests, `hack/validate-lmdb-config.sh` cross-checks the two ConfigMaps in CI on every change.

**PVC full:**

Monitor the PVC usage. In the static deployment, LMDB files and Lightning Stream snapshots share the same `4Gi` volume. KRO requests `lmdbMapSizeMB × 4Mi` (`4000Mi` by default). Both follow the same policy: 2× for the `main` and `shard` LMDB environments plus 2× snapshot/filesystem headroom.

```bash
kubectl -n dns exec deployment/pdns-auth -c lightningstream -- \
  du -sh /var/lib/powerdns /var/lib/powerdns/snapshots
```

For static manifests, raise both ConfigMap values and the PVC request while preserving the 4× policy. For KRO instances, change only `spec.lmdbMapSizeMB`; KRO expands the PVC automatically. Existing PVC expansion requires the claim's StorageClass to set `allowVolumeExpansion: true` (see `UPGRADE.md` §2.2).

### 2.4 Pod restart and recovery

**Normal restart (PVC retained):** When the Auth pod is deleted or evicted, the `Recreate` Deployment strategy starts a new pod that re-opens the existing LMDB file on the retained PVC. No zone data is lost and no manual action is required.

**Forced recovery after PVC loss:** If the PVC is deleted or corrupted, the Operator re-reconciles all `Zone` and `RRset` CRs and re-writes zone data to the Auth API after the new pod starts. Any data written directly to the Auth API without a corresponding CR is lost permanently.

> Keep all DNS configuration in `Zone` / `RRset` CRs. Direct API writes bypass the Operator and are not recovered automatically.

---

## 3 Scaling

### 3.1 Recursor and dnsdist (horizontal)

The Recursor and dnsdist are stateless and support horizontal scaling by increasing their Deployment replica count:

```bash
kubectl -n dns scale deployment/pdns-recursor --replicas=3
kubectl -n dns scale deployment/dnsdist --replicas=2
```

The `LoadBalancer` Service in front of dnsdist distributes traffic across all dnsdist pods. Each dnsdist pod load-balances independently to the Recursor pods.

### 3.2 Authoritative Server (single-instance)

In single-instance mode, the Auth Deployment uses the `Recreate` strategy because the `ReadWriteOnce` PVC cannot be mounted by two pods simultaneously. Horizontal scaling of the Auth Server requires switching to multi-instance mode.

### 3.3 Switching from single-instance to multi-instance

Multi-instance mode deploys a Garage S3 store alongside each Auth pod and uses Lightning Stream to replicate LMDB data across pods via the S3 bucket.

1. Delete the existing `PowerDNSInstance` CR:
   ```bash
   kubectl delete powerdnsinstance dns
   ```
   > Zone and record CRs are not deleted — the Operator will re-reconcile them after the new instance starts.

2. Create a new `PowerDNSInstance` with `multiInstance: true`:
   ```bash
   kubectl apply -f deploy/kro/powerdns-multi-instance-example.yaml
   ```

3. Verify both instances are running and zone data has been re-reconciled:
   ```bash
   kubectl get powerdnsinstance
   kubectl -n dns-a get zones
   ```

### 3.4 LMDB map size tuning

The default LMDB map size is `1000 MB`. For deployments with large zone counts, increase both values in the ConfigMaps and restart the Auth pod:

```bash
kubectl -n dns edit configmap pdns-auth-config         # lmdb-map-size
kubectl -n dns edit configmap lightningstream-config    # options.map_size
kubectl -n dns rollout restart deployment/pdns-auth
```

Both values must always be identical. For KRO-managed instances, increase `spec.lmdbMapSizeMB` on the `PowerDNSInstance` CR instead — it is the single source of truth and automatically requests four times that value in MiB for the PVC. For static deployments, raise `pdns-auth-data` to four times the map size as well. Decreasing the map size is unsupported because the PVC cannot be shrunk and the existing LMDB data may exceed the new ceiling.

---

## 4 Backup & Recovery

### 4.1 Single-instance backup

In single-instance mode, Lightning Stream writes LMDB snapshots to `/var/lib/powerdns/snapshots` on the Auth pod's PVC (`type: fs`). These snapshots provide a fast restart path but are co-located with the LMDB files on the same Auth volume (`4Gi` in the static deployment, `4000Mi` at the default KRO map size).

**Primary backup mechanism: Kubernetes CRs**

The most reliable backup is the set of `Zone` and `RRset` CRs stored in Kubernetes. If all DNS configuration is managed through these CRs, the Operator can fully reconstruct zone data after a PVC loss by reconciling all existing CRs against the newly started Auth Server.

Best practice: store zone and record CRs in a GitOps repository and deploy them via a standard GitOps workflow.

**PVC snapshot backup:**

Use your cluster's volume snapshot capability to back up the `pdns-auth-data` PVC:

```bash
kubectl -n dns get pvc pdns-auth-data  # confirm PVC name
# Create snapshot via your StorageClass's VolumeSnapshot support
```

### 4.2 Recovery scenarios

| Scenario | Recovery path |
|---|---|
| Pod restart, PVC retained | Automatic — new pod re-opens existing LMDB on the same PVC |
| PVC lost (single-instance) | Operator reconciles all `Zone`/`RRset` CRs and re-writes zone data; CRs are the authoritative source |
| New replica (multi-instance) | Lightning Stream downloads LMDB snapshots from Garage on startup; consistent within ~1–3 seconds |

### 4.3 Monitoring snapshot accumulation

Lightning Stream cleanup is explicitly enabled for filesystem and S3 storage. It runs every `5m`, keeps snapshots for at least `10m`, and removes stale instance histories after `168h`. Monitor available space to detect unusual write volume or failed cleanup:

```bash
kubectl -n dns exec deployment/pdns-auth -c lightningstream -- \
  du -sh /var/lib/powerdns/snapshots
```

Do not remove the explicit `storage.cleanup` block: cleanup is disabled by default in Lightning Stream 1.0.3.

### 4.4 Monitoring replication health

The Lightning Stream sidecar serves Prometheus metrics, a `/healthz` endpoint and a status page on port `8500` (`ls-metrics`). This is the primary signal that replication is working — the sidecar fails *quietly*, so a stalled sync (full PVC, unreachable Garage, invalid credentials) is otherwise invisible until zone data diverges.

```bash
# Expose the sidecar endpoints locally (no in-container tooling required)
kubectl -n dns port-forward deployment/pdns-auth 8500:8500

# Prometheus metrics (also scraped automatically by the packaged ServiceMonitor)
curl -s http://localhost:8500/metrics

# Aggregated health: 200 = healthy, 503 = sustained storage failure
curl -so /dev/null -w '%{http_code}\n' http://localhost:8500/healthz

# Snapshots currently visible in the storage backend
open http://localhost:8500/storage
```

The container probes intentionally test only that the listener is up. `/healthz` reports `503` after roughly five minutes of failing storage operations; wiring readiness to it would evict a still-serving Authoritative Server from its Service and turn degraded replication into a DNS outage. Alert on `/healthz` and on the storage error metrics instead of failing the pod.

If the sidecar is `OOMKilled`, raise `lmdbMapSizeMB` headroom rather than the limit alone — the limit is derived from it (`lmdbMapSizeMB / 2` MiB). For static deployments, raise the `lightningstream` container memory limit and the PVC together, preserving the documented ratios.

---

## 5 Update Procedures

For OCM-native version upgrades and rollback procedures, see [UPGRADE.md](UPGRADE.md).

For the rolling update strategy applied to each component (maxSurge, maxUnavailable, Recreate vs. RollingUpdate rationale), see [ARCHITECTURE.md §8.3](ARCHITECTURE.md#83-rolling-updates).

### 5.1 Rolling update strategy summary

| Component | Strategy | Reason |
|---|---|---|
| dnsdist | `RollingUpdate` (maxSurge: 1, maxUnavailable: 0) | Stateless; new pod accepts traffic before old is removed |
| Recursor | `RollingUpdate` (maxSurge: 1, maxUnavailable: 0) | Stateless; cache is rebuilt on startup |
| Operator | `RollingUpdate` (maxSurge: 1, maxUnavailable: 0) | Leader-election ensures only one active controller |
| Authoritative Server | `Recreate` | `ReadWriteOnce` PVC prevents concurrent pod mount; brief unavailability expected |

### 5.2 DNS availability during updates

This section describes the client-visible impact of a rolling update and how to
keep it within the expected envelope. It is the operator-facing companion to the
architectural analysis in [ARCHITECTURE.md §8.3](ARCHITECTURE.md#83-rolling-updates).

#### Per-component client impact

| Component | Client-visible impact | Why |
|---|---|---|
| dnsdist | None (zero-downtime) | `maxUnavailable: 0` keeps the old pod serving until the new pod passes its `:53` TCPSocket readiness probe, so the LoadBalancer always has a ready backend. |
| Recursor | No resolution outage; brief latency / cache-miss spike | The new pod takes over with no query loss, but its in-memory cache starts cold. Recently-resolved names are re-fetched from upstream once; latency normalises as the cache warms. Self-healing, no operator action required. |
| Authoritative Server | Brief unavailability of authoritative answers (~15–30 s) | The `Recreate` strategy (forced by the `ReadWriteOnce` `pdns-auth-data` PVC) terminates the old pod before the new one mounts the volume and replays LMDB. dnsdist and the Recursor stay up throughout, so cached and recursive answers continue; only authoritative lookups whose TTL has expired during the gap see a failure/retry. |
| Operator | None for DNS | Leader election means the new instance acquires the controller-runtime lease only after the old one releases it. The Operator is control-plane only and is not in the query data path. |

#### Reference update result

A reference update was executed in the test environment. dnsdist, the Recursor, and
the Operator rolled with no measurable query loss; the Authoritative Server incurred
the expected brief gap (pod termination + LMDB initialisation + readiness delay)
within the ~15–30 s window described in [ARCHITECTURE.md §8.3](ARCHITECTURE.md#83-rolling-updates).
Validation watched pod readiness transitions together with the dnsdist backend-health
and query metrics during the rollout (see *Monitoring during an update* below).

#### Operator guidance

- **Schedule Authoritative updates in a low-traffic window.** It is the only
  component with an unavoidable interruption; the others are zero-downtime.
- **Ensure node capacity for the temporary pod doubling.** `RollingUpdate` with
  `maxSurge: 1` briefly runs two pods of each affected Deployment.
- **Apply CRD schema migrations before updating the Operator.** No automated CRD
  migration tooling ships in this release; see [UPGRADE.md](UPGRADE.md).

#### Monitoring during an update

Watch the following signals to confirm a rollout stayed within the expected envelope
(metric and dashboard references in [OBSERVABILITY.md](OBSERVABILITY.md)):

- **Pod readiness** — new pods reach `Ready` before old pods terminate (dnsdist,
  Recursor, Operator); for the Authoritative Server, confirm the single pod returns
  to `Ready` after the `Recreate` cycle.
- **dnsdist backend health and query rate** — backends flip back to healthy and the
  served query rate holds steady.
- **SERVFAIL / failure rate** — a transient rise is expected only around the
  Authoritative `Recreate`; it should clear once the new pod is `Ready`.

---

## 6 Security Hardening

### 6.1 Current hardening baseline

The following measures are applied in the current release:

- **Read-only root filesystem:** Auth, Recursor, dnsdist, and Operator containers run with `readOnlyRootFilesystem: true` where feasible.
- **Non-root execution:** Containers run as non-root users; the Auth pod uses `fsGroup: 953` for PVC access.
- **No privilege escalation:** `allowPrivilegeEscalation: false` on all containers.
- **Metrics restricted to ClusterIP:** Prometheus metrics endpoints are not exposed via LoadBalancer.
- **Network policies:** The workload namespace ships a default-deny (ingress and egress) baseline with per-component allow-lists, so each pod can reach only the peers it needs. On clusters whose CNI does not enforce `NetworkPolicy` these objects are inert and harmless.

#### Network policy model

The manifests live in `deploy/base/network-policies/` and are applied by default with the bundle. Each pod starts denied in both directions; the per-component policies then re-open exactly the required flows:

| Component | Ingress allowed | Egress allowed |
|---|---|---|
| dnsdist | DNS `53/udp+tcp` from any source (public frontend) | recursor `53`, auth `53` |
| recursor | DNS `53` from dnsdist; metrics `8082/tcp` from a monitoring namespace | auth `53`; upstream resolvers `53` |
| auth | DNS `53` from recursor and dnsdist; API/metrics `8081/tcp` from the operator and a monitoring namespace | none (single-instance filesystem sync) |
| operator | metrics `8080/tcp` from a monitoring namespace | auth API `8081`; kube-apiserver `443`/`6443` |
| all pods | — | cluster DNS (kube-dns) `53` |

Notes and operator-facing requirements:

- **Monitoring source:** metrics ingress is granted to any namespace carrying the label `network-policy/monitoring: "true"`. A namespace running Prometheus (or another scraper) must carry this label, otherwise scrapes are denied. Selection is by namespace label only, so the model is portable across Prometheus distributions.
- **Health probes:** kubelet liveness/readiness probes are not subject to network policy enforcement, so no node-level allowances are required.
- **Upstream resolver egress:** the recursor is permitted egress to `0.0.0.0/0` on port `53` because the forwarders are configurable. Narrow this to the specific forwarder addresses via an overlay for a stricter posture.
- **kube-apiserver egress:** the operator is allowed egress on `443`/`6443` to any address because the API server endpoint is not a selectable pod and varies by platform. The grant is restricted by port.
- Enforcement is exercised in CI by `hack/validate-network-policies.sh` (also run as the `network-policies` suite of `hack/validate-cluster.sh`), which proves both that denied flows are blocked and that allowed flows still work.

#### DNS rate limiting and abuse mitigation

The dnsdist frontend applies the following controls before routing a query to the Recursor or Authoritative backends. They are defined in `deploy/base/dnsdist/configmap.yaml` (and the equivalent multi-instance resource graph definition):

- **Global query-rate safety valve:** traffic exceeding a coarse aggregate ceiling is dropped to protect the backends from overload. This is a blunt aggregate control, not a per-client abuse limit.
- **Anti-amplification:** `ANY` queries arriving over UDP are answered truncated (`TC=1`) so legitimate clients retry over TCP, while spoofed-source UDP reflection attempts receive only a small truncated reply. Queries that already use TCP are unaffected.
- **Per-client rate limit (opt-in):** drops traffic from a single client IP that exceeds a configured rate. It is **disabled by default** because it is only effective when dnsdist observes the real client source address. Behind a `LoadBalancer` Service with the default `externalTrafficPolicy: Cluster`, client IPs are source-NAT'd to a single address, so enabling per-client limiting without first preserving the client IP would throttle all clients collectively. Preserve the client IP (for example `externalTrafficPolicy: Local`, or an IP-preserving load balancer) before enabling it.

Tunable via environment variables on the dnsdist container (unset values fall back to the defaults):

| Variable | Default | Effect |
|---|---|---|
| `DNSDIST_MAX_QPS` | `1000` | Aggregate queries-per-second ceiling; traffic above it is dropped. Set to `0` to disable the global cap. |
| `DNSDIST_MAX_QPS_PER_CLIENT` | `0` (disabled) | Per-client-IP queries-per-second limit; set to a positive value only once client-IP preservation is in place. |

Size `DNSDIST_MAX_QPS` to the Recursor/Auth capacity for your environment. The defaults are conservative starting points, not certified thresholds.

### 6.2 Security review summary

The bundle has undergone a baseline security review. The scope is baseline hardening — minimized runtime permissions, restrictive network configuration, image vulnerability scanning, and DNS-specific abuse mitigation. No claim is made to formal certification or full STIG/CIS compliance. The table below summarizes the control areas and their status.

| Control area | Status | Evidence / location |
|---|---|---|
| Container image CVE scanning | Implemented (blocking gate) | Per-image Trivy scan with SARIF upload to the code scanning tab, aggregated by a single required gate check that fails the build on new `HIGH`/`CRITICAL` findings. A small set of fix-available upstream findings is time-boxed in `.trivyignore.yaml`. See §6.3. |
| Image provenance and pinning | Implemented | All images pinned by immutable digest; per-image SBOM generated; an inventory check enforces that the package declares exactly the images the manifests deploy. |
| Pod Security Standards | Implemented (Baseline enforced; Restricted warned/audited) | The application namespace carries `pod-security.kubernetes.io/enforce: baseline` and `warn`/`audit: restricted`. |
| Non-root, no privilege escalation, capability drop, seccomp | Implemented | Every workload sets `runAsNonRoot`, `allowPrivilegeEscalation: false`, drops all capabilities (only `NET_BIND_SERVICE` re-added for port 53), and `seccompProfile: RuntimeDefault`. |
| Read-only root filesystem | Implemented | `readOnlyRootFilesystem: true` on the DNS/operator containers. |
| Network segmentation | Implemented (requires an enforcing CNI) | Default-deny baseline plus per-component allow-lists; enforcement validated in CI. See §6.1. |
| DNS abuse mitigation | Implemented | dnsdist global QPS safety valve and UDP `ANY` truncation; opt-in per-client limit. See §6.1. |
| External exposure minimization | Implemented | Only the dnsdist Service is exposed (`LoadBalancer`); all other Services are `ClusterIP`. |
| Secrets management | Partial | The multi-instance topology injects the Authoritative API key from a Kubernetes Secret; the single-instance base ships a placeholder API key that must be overridden. See §6.3. |

### 6.3 Residual risks, exceptions, and assumptions

The following items are known residual risks, accepted exceptions, or operating assumptions. Each lists the action required to close or mitigate it.

| # | Item | Scope | Mitigation / required action |
|---|---|---|---|
| 1 | The single-instance base ships the Authoritative API key as a placeholder (`api-key=changeme`). | Single-instance base | Override the key via an overlay or Kubernetes Secret before exposing the cluster. Access to the API port is already constrained to the operator and a monitoring namespace by network policy. |
| 2 | The Authoritative (`8081`) and Recursor (`8082`) webservers use `webserver-allow-from=0.0.0.0/0`. | Base | Access is constrained at the network layer by the NetworkPolicies. For defense-in-depth, tighten `webserver-allow-from` to the pod CIDR via an overlay. |
| 3 | The image CVE scan gate is blocking, but a set of fix-available `HIGH`/`CRITICAL` findings in upstream base images and third-party modules is suppressed via a time-boxed allowlist. | CI/CD | Each entry in `.trivyignore.yaml` carries a justification and an `expired-at` date; on expiry the finding re-fails the gate and must be re-triaged. Close items by bumping to a rebuilt upstream image/digest as they become available. See the allowlist renewal runbook in [CI-CD.md](CI-CD.md#handling-cve-findings-and-renewing-the-allowlist). |
| 4 | NetworkPolicies are inert on a CNI that does not enforce them. | All | The deployment assumes the target CNI enforces `NetworkPolicy` (for example the AWS VPC CNI with network-policy enforcement enabled). Verify enforcement on the target cluster. |
| 5 | Per-client DNS rate limiting is disabled by default. | All | Under the default `externalTrafficPolicy: Cluster` the LoadBalancer source-NATs client IPs. Preserve the client IP and then enable `DNSDIST_MAX_QPS_PER_CLIENT` (see §6.1). |
| 6 | The Recursor is allowed egress to `0.0.0.0/0` on port `53`. | Base | The upstream forwarders are configurable, so the egress is broad-by-port. Narrow it to the specific resolver addresses via an overlay for a stricter posture. |
| 7 | The Operator is allowed egress to `0.0.0.0/0` on ports `443`/`6443`. | Base | The kube-apiserver endpoint is not a selectable pod and varies by platform, so the grant is restricted by port only. |
| 8 | The application namespace enforces the Pod Security **Baseline** profile, not **Restricted**. | All | Two workloads require Baseline (items 9 and 10). All other workloads already satisfy Restricted and are warned/audited against it. |
| 9 | The Authoritative `repair-lmdb-permissions` initContainer runs as root. | Authoritative | It only chowns the LMDB volume; it drops all capabilities except `CHOWN` and sets `allowPrivilegeEscalation: false`. Required because the PVC is provisioned root-owned. |
| 10 | The Garage S3 store and its bootstrap sidecar run as root. | Multi-instance only | Garage ships as a `scratch` image; this exception is isolated to the multi-instance replication topology and does not apply to the single-instance base. |
| 11 | Multi-instance (KRO) NetworkPolicies are not yet shipped. | Multi-instance | The single-instance base is fully covered; equivalent policies for the multi-instance topology are a tracked follow-up. |
| 12 | No formal certification or full STIG/CIS compliance is claimed. | All | The scope is baseline hardening per the agreed requirements; formal certification is out of scope unless separately agreed. |

For the security architecture overview, see [ARCHITECTURE.md §8.2](ARCHITECTURE.md#82-security-and-hardening).
