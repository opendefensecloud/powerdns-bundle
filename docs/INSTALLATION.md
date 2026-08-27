# Installation Guide

This guide walks through deploying the PowerDNS bundle on a Kubernetes cluster using KRO (Kubernetes Resource Operator). It covers the online single-instance and multi-instance scenarios. For air-gap environments see [AIR-GAP-DEPLOYMENT.md](AIR-GAP-DEPLOYMENT.md).

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Install the KRO ResourceGraphDefinition](#2-install-the-kro-resourcegraphdefinition)
3. [Deploy: Single-instance](#3-deploy-single-instance)
4. [Verify the installation](#4-verify-the-installation)
5. [Deploy: Multi-instance](#5-deploy-multi-instance)
6. [Air-gap deployment](#6-air-gap-deployment)
7. [Production preflight checklist](#7-production-preflight-checklist)
8. [Next steps](#8-next-steps)

---

## 1 Prerequisites

### Tooling

| Tool | Minimum version | Purpose |
|---|---|---|
| `kubectl` | 1.27 | Cluster interaction |
| `kro` | any stable release | KRO controller must be running in the cluster |

### Cluster requirements

| Requirement | Details |
|---|---|
| Kubernetes | 1.27 or later |
| KRO | Installed and running (`kubectl get crd resourcegraphdefinitions.kro.run` must succeed) |
| StorageClass | At least one `ReadWriteOnce`-capable StorageClass must exist; the default StorageClass is used unless overridden. Existing installations upgrading from the previous 1Gi Auth PVC require `allowVolumeExpansion: true` (see `UPGRADE.md` §2.2). |
| Internet access | Required for online installation (images pulled from upstream registries); see [Section 6](#6-air-gap-deployment) for air-gap |

### Network

The bundle exposes DNS on port `53` (UDP and TCP) via a `LoadBalancer` Service. The cluster must be able to provision `LoadBalancer` Services, or you must update the Service type before applying.

---

## 2 Install the KRO ResourceGraphDefinition

The `PowerDNSInstance` custom resource is defined in a KRO `ResourceGraphDefinition` (RGD). Apply it once per cluster:

```bash
kubectl apply -f deploy/kro/powerdns-instance-rgd.yaml
```

Verify the RGD is ready:

```bash
kubectl get resourcegraphdefinition powerdnsinstance
# Expected: READY = True
```

This step also installs the `PowerDNSInstance` CRD and all four DNS Custom Resource Definitions (`Zone`, `ClusterZone`, `RRset`, `ClusterRRset`) on the cluster.

---

## 3 Deploy: Single-instance

A single instance runs one complete DNS stack (dnsdist + Recursor + Authoritative Server + Operator) in an isolated namespace. Zone data is stored on a local PVC; no S3 store is required.

### 3.1 Create a PowerDNSInstance resource

Replace `changeme` with a strong API key — it is a development placeholder used
by the bundled examples and the CI validation scripts, not a usable secret.
Generate one with `openssl rand -hex 32`. The key is used internally between the
Operator and the Authoritative Server; KRO injects it into both the Authoritative
config and the Operator Secret from this single field, so the two cannot drift
apart. See the [production preflight checklist](#7-production-preflight-checklist)
before serving real traffic.

```yaml
# powerdns-instance.yaml
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: dns
  namespace: default
spec:
  namespace: dns        # target namespace — all DNS components are deployed here
  pdnsApiKey: changeme  # DEVELOPMENT PLACEHOLDER — replace: openssl rand -hex 32
  multiInstance: false
  lmdbMapSizeMB: 1000   # default; provisions a 4000Mi Auth PVC automatically
```

```bash
kubectl apply -f powerdns-instance.yaml
```

`lmdbMapSizeMB` is the single map-size setting for PowerDNS and Lightning
Stream (minimum `256`, default `1000`). KRO provisions 4Mi of Auth PVC capacity
per configured MB: two shares for the `main` and `shard` LMDB environments and
two shares for snapshots and storage overhead. Increasing the map size therefore
expands the PVC and, in multi-instance mode, the Garage layout capacity in
lockstep. The cluster StorageClass must allow expansion when changing this field
on an existing instance. Map size and persistent storage can only be increased;
Kubernetes does not support shrinking an existing PVC.

You can also use the bundled reference example directly:

```bash
kubectl apply -f deploy/kro/powerdns-instance-example.yaml
```

### 3.2 Monitor deployment

KRO creates all resources in the target namespace. Track progress:

```bash
kubectl get powerdnsinstance dns -w
kubectl -n dns get pods -w
```

All four pods (`pdns-operator`, `pdns-auth`, `pdns-recursor`, `dnsdist`) should reach `Running` state within a few minutes.

---

## 4 Verify the installation

### Check pod health

```bash
kubectl -n dns get pods
# Expected: all pods Running, READY column all-green
```

### Check DNS resource status

```bash
kubectl get powerdnsinstance dns
# Expected: READY column shows True (or equivalent healthy state)
```

### Create a test zone and record

```bash
kubectl -n dns apply -f deploy/examples/zone-reference-scenario.yaml
kubectl -n dns get zones
kubectl -n dns get rrsets
```

The Operator reconciles the zone and records against the Authoritative Server. Both resources should show `syncStatus: Active` or `Succeeded` in their status.

### Query DNS

Once the `dnsdist` LoadBalancer Service has an external IP assigned:

```bash
EXTERNAL_IP=$(kubectl -n dns get svc dnsdist -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
dig @"$EXTERNAL_IP" intern.example.com SOA
```

An authoritative response (`aa` flag set) confirms the Authoritative Server is reachable through the DNS frontend.

---

## 5 Deploy: Multi-instance

Multi-instance mode deploys two or more independent DNS stacks. Each instance has its own namespace, API key, and Garage S3 store. Lightning Stream replicates zone data between Auth pods within the same instance via the S3 bucket.

> Multi-instance is a horizontal-scale and failure-isolation pattern. Each `PowerDNSInstance` is independently managed and runs its own complete DNS stack.

### 5.1 Deploy two instances

```yaml
# dns-a.yaml
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: dns-a
  namespace: default
spec:
  namespace: dns-a
  pdnsApiKey: changeme-a   # DEVELOPMENT PLACEHOLDER — replace; use a distinct key per instance
  multiInstance: true
  lmdbMapSizeMB: 1000

---
# dns-b.yaml
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: dns-b
  namespace: default
spec:
  namespace: dns-b
  pdnsApiKey: changeme-b   # DEVELOPMENT PLACEHOLDER — replace; use a distinct key per instance
  multiInstance: true
  lmdbMapSizeMB: 1000
```

```bash
kubectl apply -f dns-a.yaml
kubectl apply -f dns-b.yaml
```

Or use the bundled example:

```bash
kubectl apply -f deploy/kro/powerdns-multi-instance-example.yaml
```

### 5.2 Verify isolation

```bash
kubectl get powerdnsinstance
kubectl -n dns-a get pods
kubectl -n dns-b get pods
```

Both instances must run independently. Delete instance `dns-a` and verify `dns-b` continues operating:

```bash
kubectl delete powerdnsinstance dns-a
kubectl -n dns-b get pods   # all pods must still be Running
```

### 5.3 Garage S3 initialisation

When `multiInstance: true`, KRO adds a Garage pod to each instance. Garage bootstraps its single-node cluster layout, S3 access key, and Lightning Stream bucket automatically on first startup. No manual Garage configuration is needed for the reference scenario.

---

## 6 Air-gap deployment

Air-gap installation requires all container images to be present in a private registry. See [AIR-GAP-DEPLOYMENT.md](AIR-GAP-DEPLOYMENT.md) for the full procedure, which covers:

- Building and bundling the OCM component archive
- Pushing images to a private registry
- Generating the localized manifests overlay
- Applying the air-gap overlay

---

## 7 Production preflight checklist

The bundled defaults are tuned for a reproducible reference deployment, not for
an exposed production environment. Work through this list before serving real
traffic. Each item links to the section that explains it in full.

| # | Check | Why | Reference |
|---|---|---|---|
| 1 | **Replace the API key.** Set `spec.pdnsApiKey` to a generated value (`openssl rand -hex 32`). Never keep `changeme` / `changeme-a` / `changeme-b`. | The key authenticates the Operator against the Authoritative HTTP API. It is a well-known placeholder in the examples and CI scripts. | [§3.1](#31-create-a-powerdnsinstance-resource), [OPERATIONS.md §6.3 item 1](OPERATIONS.md#63-residual-risks-exceptions-and-assumptions) |
| 2 | **Store the key outside Git.** Source it from a secret manager (External Secrets Operator, Vault, SOPS) rather than committing it to the manifest. | The static base ships the key as a plain `Secret` manifest. | [OPERATIONS.md §6.2](OPERATIONS.md#62-security-review-summary) |
| 3 | **Verify the CNI enforces `NetworkPolicy`.** Apply a deny test, or run `hack/validate-network-policies.sh` against the target cluster. | The whole network segmentation model is inert on a non-enforcing CNI, and the broad application-level ACLs then become the real boundary. | [OPERATIONS.md §6.1](OPERATIONS.md#61-current-hardening-baseline) |
| 4 | **Set your own upstream forwarders.** Replace `forward-zones-recurse=.=1.1.1.1;8.8.8.8` with the internal resolvers, or remove the line for full root recursion. | The defaults are public resolvers and leak query metadata outside the organisation. | `deploy/base/recursor/configmap.yaml` |
| 5 | **Restrict the DNS LoadBalancer.** Set `loadBalancerSourceRanges` on the dnsdist Service unless the resolver is intentionally public. | The Service is created without source restrictions; an open resolver is an amplification risk. | [OPERATIONS.md §6.4](OPERATIONS.md#64-hardening-overlay-examples) |
| 6 | **Decide on per-client rate limiting.** If client IPs are preserved (`externalTrafficPolicy: Local` or an IP-preserving LB), set `DNSDIST_MAX_QPS_PER_CLIENT`; otherwise size the global `DNSDIST_MAX_QPS` to the backend capacity. | Per-client limiting is disabled by default because the default `Cluster` policy source-NATs all clients to one address. | [OPERATIONS.md §6.1](OPERATIONS.md#61-current-hardening-baseline) |
| 7 | **Size `lmdbMapSizeMB` for the expected zone volume.** The PVC (4Mi per MB) and the Garage layout are derived from it. Confirm the StorageClass sets `allowVolumeExpansion: true`. | Map size and PVC can be increased later but never shrunk; expansion requires StorageClass support. | [§3.1](#31-create-a-powerdnsinstance-resource), [OPERATIONS.md §3.4](OPERATIONS.md#34-lmdb-map-size-tuning) |
| 8 | **Label the monitoring namespace** with `network-policy/monitoring: "true"`. | Metrics ingress is granted by namespace label only; without it every scrape is denied by NetworkPolicy. | [OPERATIONS.md §6.1](OPERATIONS.md#61-current-hardening-baseline), [OBSERVABILITY.md](OBSERVABILITY.md) |
| 9 | **Confirm alerting on replication health.** Alert on the Lightning Stream `/healthz` endpoint and storage error metrics on port `8500`. | The sidecar fails quietly; a stalled sync is invisible until zone data diverges. | [OPERATIONS.md §4.4](OPERATIONS.md#44-monitoring-replication-health) |
| 10 | **Acknowledge the Authoritative availability ceiling.** The Authoritative Server runs a single replica with a `ReadWriteOnce` PVC and a `Recreate` update strategy, so it is briefly unavailable during updates and node failures. Recursor and dnsdist absorb this for cached queries only. | This is a design property of the single-instance topology, not a defect. Plan maintenance windows or use the multi-instance topology. | [OPERATIONS.md §5.2](OPERATIONS.md#52-dns-availability-during-updates), [ARCHITECTURE.md](ARCHITECTURE.md) |
| 11 | **Take a backup path decision.** Confirm the StorageClass supports `VolumeSnapshot`, or rely on `Zone`/`RRset` CRs as the source of truth with a GitOps backup of those CRs. | PVC loss is recoverable from the CRs, but only if the CRs themselves are backed up. | [OPERATIONS.md §4](OPERATIONS.md#4-backup--recovery) |
| 12 | **Review the residual risk register** and record which exceptions are accepted for your environment. | Several broad-by-design grants (recursor egress, operator API-server egress, Pod Security Baseline) are documented exceptions that need an explicit owner decision. | [OPERATIONS.md §6.3](OPERATIONS.md#63-residual-risks-exceptions-and-assumptions) |

---

## 8 Next steps

| Topic | Document |
|---|---|
| DNS Custom Resource API (zones, records, fields, examples) | [CRD-SPECIFICATION.md](CRD-SPECIFICATION.md) |
| Day-2 operations (monitoring, troubleshooting, backup, updates) | [OPERATIONS.md](OPERATIONS.md) |
| Metrics endpoints and Prometheus integration | [OBSERVABILITY.md](OBSERVABILITY.md) |
| Version upgrades and rollback | [UPGRADE.md](UPGRADE.md) |
| Architecture and design decisions | [ARCHITECTURE.md](ARCHITECTURE.md) |
