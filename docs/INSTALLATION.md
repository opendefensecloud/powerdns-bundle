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
7. [Next steps](#7-next-steps)

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
| StorageClass | At least one `ReadWriteOnce`-capable StorageClass must exist; the default StorageClass is used unless overridden |
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

Replace `changeme` with a strong API key. The key is used internally between the Operator and the Authoritative Server.

```yaml
# powerdns-instance.yaml
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: dns
  namespace: default
spec:
  namespace: dns        # target namespace — all DNS components are deployed here
  pdnsApiKey: changeme  # replace with a strong random key
  multiInstance: false
```

```bash
kubectl apply -f powerdns-instance.yaml
```

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
  pdnsApiKey: changeme-a   # replace
  multiInstance: true

---
# dns-b.yaml
apiVersion: kro.run/v1alpha1
kind: PowerDNSInstance
metadata:
  name: dns-b
  namespace: default
spec:
  namespace: dns-b
  pdnsApiKey: changeme-b   # replace
  multiInstance: true
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

## 7 Next steps

| Topic | Document |
|---|---|
| DNS Custom Resource API (zones, records, fields, examples) | [CRD-SPECIFICATION.md](CRD-SPECIFICATION.md) |
| Day-2 operations (monitoring, troubleshooting, backup, updates) | [OPERATIONS.md](OPERATIONS.md) |
| Metrics endpoints and Prometheus integration | [OBSERVABILITY.md](OBSERVABILITY.md) |
| Version upgrades and rollback | [UPGRADE.md](UPGRADE.md) |
| Architecture and design decisions | [ARCHITECTURE.md](ARCHITECTURE.md) |
