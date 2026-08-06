# CRD Specification: PowerDNS Operator Custom Resources

**Status:** Approved
**Source:** PowerDNS Operator OSS ([powerdns-operator/PowerDNS-Operator](https://github.com/powerdns-operator/PowerDNS-Operator))
**Bundled revision:** [`telekom/PowerDNS-Operator@1a1bf0c`](https://github.com/telekom/PowerDNS-Operator/commit/1a1bf0c19fc86512cc3b13829e298a99c3aa7d93), based on upstream [`255d6b0`](https://github.com/powerdns-operator/PowerDNS-Operator/commit/255d6b01372aa94118d2e875553af783fb5062e4)
**API Group / Version:** `dns.cav.enablers.ob/v1alpha2`

---

## Contents

1. [Overview](#1-overview)
2. [Zone](#2-zone)
3. [ClusterZone](#3-clusterzone)
4. [RRset](#4-rrset)
5. [ClusterRRset](#5-clusterrrset)
6. [Status Design](#6-status-design)
   - 6.6 [`kubectl get` tabular output](#66-kubectl-get-tabular-output)
   - 6.7 [`kubectl describe` status section](#67-kubectl-describe-status-section)
7. [Record Type Reference](#7-record-type-reference)
8. [Design Notes and Open Points](#8-design-notes-and-open-points)

---

## 1 Overview

The PowerDNS Operator OSS manages DNS zones and resource record sets in the PowerDNS Authoritative Server through four Custom Resource Definitions (CRDs). All CRDs are in the API group `dns.cav.enablers.ob`, version `v1alpha2`.

| CRD | Scope | Purpose |
|---|---|---|
| `Zone` | Namespace | DNS zone, isolated per namespace |
| `ClusterZone` | Cluster | DNS zone, available across all namespaces |
| `RRset` | Namespace | Resource record set, references a `Zone` or `ClusterZone` |
| `ClusterRRset` | Cluster | Resource record set, references a `ClusterZone` |

**Naming convention:** for record resources, `spec.name` carries the DNS name (for example `app.intern.example.com.`). `metadata.name` remains the Kubernetes object name and is usually kept aligned without the trailing dot.

---

## 2 Zone

A `Zone` CR represents a DNS zone managed by the PowerDNS Authoritative Server. It is namespace-scoped, which means two namespaces may hold independently managed zones with the same DNS name (each backed by a separate Auth instance in multi-instance deployments).

### 2.1 Schema

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: <fqdn-without-trailing-dot>   # e.g. intern.example.com
  namespace: <namespace>
spec:
  kind: <zone-kind>         # Required — see §2.2
  nameservers:              # Required — at least one entry
    - <ns-hostname>         # e.g. ns1.intern.example.com
  catalog: <catalog-zone>   # Optional — catalog zone name for automatic NS distribution
  account: <account>        # Optional — account label passed to PowerDNS API
```

### 2.2 `spec.kind` values

| Value | Meaning |
|---|---|
| `Native` | Single-instance zone, no AXFR replication. Recommended for this project. |
| `Master` | Zone acts as primary; secondaries pull via AXFR. |
| `Slave` | Zone acts as secondary; pulls from a primary. |

### 2.3 `spec.nameservers`

A list of authoritative name server hostnames for this zone. The Operator inserts corresponding `NS` records into PowerDNS. At least one entry is required.

### 2.4 Optional fields

| Field | Type | Description |
|---|---|---|
| `spec.catalog` | string | Name of a catalog zone. When set, the zone is added to the named catalog, enabling automatic delegation distribution to secondaries. Leave empty in Native/single-instance deployments. |
| `spec.account` | string | Arbitrary label passed as the `account` field to the PowerDNS API. Used for multi-tenant tagging or filtering; has no effect on DNS resolution itself. |

### 2.5 Example

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: Zone
metadata:
  name: intern.example.com
  namespace: dns
spec:
  kind: Native
  nameservers:
    - ns1.intern.example.com
    - ns2.intern.example.com
```

---

## 3 ClusterZone

`ClusterZone` is the cluster-scoped counterpart of `Zone`. It has an identical `spec` structure. Use `ClusterZone` when the DNS zone must be reachable from multiple namespaces without duplication, or when a single Operator instance manages zones for all namespaces.

### 3.1 Schema

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: ClusterZone
metadata:
  name: <fqdn-without-trailing-dot>
spec:
  kind: <zone-kind>         # Required — same values as Zone §2.2
  nameservers:              # Required
    - <ns-hostname>
  catalog: <catalog-zone>   # Optional
  account: <account>        # Optional
```

### 3.2 Example

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: ClusterZone
metadata:
  name: cluster.example.com
spec:
  kind: Native
  nameservers:
    - ns1.cluster.example.com
```

---

## 4 RRset

An `RRset` CR represents a DNS resource record set inside a zone. It is namespace-scoped and must reference a `Zone` (or `ClusterZone`) in the same namespace.

### 4.1 Schema

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: <kubernetes-object-name>
  namespace: <namespace>
spec:
  name: <fqdn>              # Required — full record name, e.g. app.intern.example.com.
  type: <record-type>       # Required — see §7
  ttl: <seconds>            # Required — positive integer, e.g. 300
  records:                  # Required — at least one entry
    - <value>               # Type-dependent content string (see §7)
  comment: <text>           # Optional — freeform comment stored in PowerDNS
  zoneRef:                  # Required
    name: <zone-name>       # metadata.name of the Zone or ClusterZone
    kind: Zone              # "Zone" or "ClusterZone"
```

### 4.2 `spec.records`

Each entry in `records` is a string in the PowerDNS record content format:

Multiple entries produce an RRset with multiple values (for example round-robin A records).

### 4.3 `spec.zoneRef`

| Field | Description |
|---|---|
| `name` | The `metadata.name` of the Zone or ClusterZone this record belongs to |
| `kind` | `Zone` (namespace-scoped) or `ClusterZone` (cluster-scoped) |

### 4.4 Examples

**A record (single value):**

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: app.intern.example.com
  namespace: dns
spec:
  name: app.intern.example.com.
  type: A
  ttl: 300
  records:
    - "10.0.5.12"
  zoneRef:
    name: intern.example.com
    kind: Zone
```

**A record (round-robin):**

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: lb.intern.example.com
  namespace: dns
spec:
  name: lb.intern.example.com.
  type: A
  ttl: 60
  records:
    - "10.0.5.10"
    - "10.0.5.11"
    - "10.0.5.12"
  zoneRef:
    name: intern.example.com
    kind: Zone
```

**CNAME record:**

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: www.intern.example.com
  namespace: dns
spec:
  name: www.intern.example.com.
  type: CNAME
  ttl: 300
  records:
    - "app.intern.example.com."
  zoneRef:
    name: intern.example.com
    kind: Zone
```

**MX record:**

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: intern.example.com
  namespace: dns
spec:
  name: intern.example.com.
  type: MX
  ttl: 3600
  records:
    - "10 mail.intern.example.com."
    - "20 mail2.intern.example.com."
  zoneRef:
    name: intern.example.com
    kind: Zone
```

**TXT record:**

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: RRset
metadata:
  name: intern.example.com
  namespace: dns
spec:
  name: intern.example.com.
  type: TXT
  ttl: 3600
  records:
    - '"v=spf1 mx -all"'
  zoneRef:
    name: intern.example.com
    kind: Zone
```

---

## 5 ClusterRRset

`ClusterRRset` is the cluster-scoped counterpart of `RRset`. It has an identical `spec` structure, but `spec.zoneRef.kind` must be `ClusterZone` (a `ClusterRRset` cannot reference a namespace-scoped `Zone`).

### 5.1 Schema

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: ClusterRRset
metadata:
  name: <kubernetes-object-name>
spec:
  name: <fqdn>
  type: <record-type>
  ttl: <seconds>
  records:
    - <value>
  comment: <text>           # Optional
  zoneRef:
    name: <cluster-zone-name>
    kind: ClusterZone       # Must be ClusterZone for ClusterRRset
```

### 5.2 Example

```yaml
apiVersion: dns.cav.enablers.ob/v1alpha2
kind: ClusterRRset
metadata:
  name: api.cluster.example.com
spec:
  name: api.cluster.example.com.
  type: A
  ttl: 300
  records:
    - "10.1.0.5"
  zoneRef:
    name: cluster.example.com
    kind: ClusterZone
```

---

## 6 Status Design

The CRDs expose a `status` section for reconciliation feedback. With the operator version used by this bundle, Zone resources report PowerDNS zone metadata after reconciliation, and RRset resources report DNS record synchronization state.

### 6.1 Status schema

```yaml
status:
  observedGeneration: <integer>     # generation of the spec that was last reconciled
  syncStatus: <sync-state>          # coarse-grained state — see §6.2
  id: <zone-id>                     # Zone/ClusterZone: PowerDNS zone identifier
  name: <zone-fqdn>                 # Zone/ClusterZone: PowerDNS zone name
  kind: <zone-kind>                 # Zone/ClusterZone: reconciled zone kind
  serial: <integer>                 # Zone/ClusterZone: SOA serial
  notified_serial: <integer>        # Zone/ClusterZone: last notified SOA serial
  edited_serial: <integer>          # Zone/ClusterZone: edited SOA serial
  masters: [<ip-address>]           # Zone/ClusterZone: configured masters for secondary zones
  dnssec: <boolean>                 # Zone/ClusterZone: DNSSEC signing state
  catalog: <catalog-zone>           # Zone/ClusterZone: catalog zone membership
  dnsEntryName: <fqdn>              # reconciled DNS entry name, set on successful RRset sync
  lastUpdateTime: <rfc3339>         # last successful RRset sync time
  conditions:
    - type: <condition-type>        # e.g. "Available"; set when the operator reports detailed state
      status: "True" | "False" | "Unknown"
      reason: <reason-token>        # machine-readable short reason
      message: <human-readable>     # human-readable description; error detail when failing
      observedGeneration: <integer>
      lastTransitionTime: <rfc3339>
```

### 6.2 `status.syncStatus` values

| Value | Meaning |
|---|---|
| `Succeeded` | Resource is fully reconciled; PowerDNS reflects the desired state |
| `Pending` | Reconciliation in progress or the resource is awaiting a dependency |
| `Failed` | Reconciliation failed in the current operator; see `conditions` for error detail |
| `Active` / `Error` | Accepted for compatibility with earlier status conventions |

### 6.3 Condition types

| Type | Normal value | Meaning |
|---|---|---|
| `Available` | `True` after successful reconciliation; `False` / `Unknown` on unresolved dependencies or errors | The desired DNS state is not yet live when false; inspect `message` for the cause |

The `reason` field uses token values such as `Succeeded`, `SynchronizationFailed`, `ZoneMissing`, `ZoneNotAvailable`, and `Duplicated`. `ZoneMissing` means the referenced Zone does not exist, while `ZoneNotAvailable` means it exists but is not available. The `message` field contains a human-readable explanation and is the primary field to inspect when troubleshooting. Successful reconciliation reports an `Available: "True"` condition in addition to `syncStatus: Succeeded` and resource-specific status fields.

### 6.4 Typical RRset status after successful sync

```yaml
status:
  conditions:
    - type: Available
      status: "True"
      reason: Succeeded
      message: Succeeded
      observedGeneration: 3
      lastTransitionTime: "2026-04-28T10:00:00Z"
  dnsEntryName: app.intern.example.com.
  lastUpdateTime: "2026-04-28T10:00:00Z"
  observedGeneration: 3
  syncStatus: Succeeded
```

Successful Zone reconciliation reports PowerDNS zone metadata:

```yaml
status:
  catalog: ""
  conditions:
    - type: Available
      status: "True"
      reason: Succeeded
      message: Succeeded
      observedGeneration: 3
      lastTransitionTime: "2026-04-28T10:00:00Z"
  dnssec: false
  edited_serial: 2026042801
  id: intern.example.com
  kind: Native
  name: intern.example.com.
  notified_serial: 2026042801
  observedGeneration: 3
  serial: 2026042801
  syncStatus: Succeeded
```

### 6.5 Typical status for unresolved dependencies

```yaml
status:
  observedGeneration: 3
  syncStatus: Pending
  conditions:
    - type: Available
      status: "False"
      reason: ZoneMissing
      message: "Missing Zone:Zone.dns.cav.enablers.ob \"missing-zone.example\" not found"
      observedGeneration: 3
      lastTransitionTime: "2026-04-28T10:00:00Z"
```

For a missing `zoneRef`, the current operator image treats the RRset as pending because the dependency may be created later. The condition reason and message provide the troubleshooting detail.

### 6.6 `kubectl get` tabular output

RRset resources expose a **Sync** column derived from `status.syncStatus`. The column is visible in the default tabular output of `kubectl get` without additional flags.

RRset example — including one record awaiting a missing zone reference:

```
$ kubectl get rrset -n dns
NAME                          TYPE   TTL   ZONE                    SYNC       AGE
app.intern.example.com        A      300   intern.example.com      Succeeded  10m
orphan.missing-zone.example   A      300   missing-zone.example    Pending    30s
```

The **Sync** column provides at-a-glance status without needing to inspect the full status block.

### 6.7 `kubectl describe` status section

`kubectl describe` displays the full status block. Failed reconciliation includes condition fields with troubleshooting detail. Below are representative RRset outputs for the two main scenarios. Zone resources similarly show PowerDNS metadata such as serials, DNSSEC state, and the reconciled zone identifier.

**Successful reconciliation:**

```
$ kubectl describe rrset app.intern.example.com -n dns
...
Status:
  Conditions:
    Last Transition Time:  2026-04-28T10:00:00Z
    Message:               Succeeded
    Observed Generation:   1
    Reason:                Succeeded
    Status:                True
    Type:                  Available
  Dns Entry Name:           app.intern.example.com.
  Last Update Time:         2026-04-28T10:00:00Z
  Observed Generation:     1
  Sync Status:             Succeeded
```

**Unresolved dependency (zone not found):**

```
$ kubectl describe rrset orphan.missing-zone.example -n dns
...
Status:
  Conditions:
    Last Transition Time:  2026-04-28T10:01:00Z
    Message:               Missing Zone:Zone.dns.cav.enablers.ob "missing-zone.example" not found
    Observed Generation:   1
    Reason:                ZoneMissing
    Status:                False
    Type:                  Available
  Observed Generation:     1
  Sync Status:             Pending
```

When troubleshooting, always inspect the `Message` field — it contains the human-readable error detail that identifies the root cause.

---

## 7 Record Type Reference

The following record types are supported by the PowerDNS Operator OSS. The **base scope** (A, AAAA, CNAME, MX, TXT) is the minimum agreed with the client for initial implementation. Additional types are listed for completeness.

| Type | Scope | `content` format | Example content |
|---|---|---|---|
| `A` | Base | IPv4 address | `10.0.5.12` |
| `AAAA` | Base | IPv6 address | `2001:db8::1` |
| `CNAME` | Base | Target FQDN with trailing dot | `app.intern.example.com.` |
| `MX` | Base | `<priority> <target-fqdn.>` | `10 mail.intern.example.com.` |
| `TXT` | Base | Quoted string(s) | `"v=spf1 mx -all"` |
| `NS` | Extended | NS hostname with trailing dot | `ns1.intern.example.com.` |
| `SRV` | Extended | `<priority> <weight> <port> <target.>` | `10 20 443 svc.intern.example.com.` |
| `CAA` | Extended | `<flag> <tag> <value>` | `0 issue "letsencrypt.org"` |
| `PTR` | Extended | Target FQDN with trailing dot | `app.intern.example.com.` |

**Important formatting rules:**
- FQDNs used as record content (CNAME target, MX target, NS, PTR, SRV target) must include the trailing dot.
- TXT record content must be enclosed in double quotes within the `content` string.
- MX and SRV records encode priority as the first space-separated token in the content string.

---

## 8 Design Notes and Open Points

### 8.1 Scope boundaries

The Operator CRDs exclusively manage the **Authoritative Server** (zone data, records). They do not configure the Recursor (forwarding rules) or dnsdist (routing, rate limiting). Those components are configured via ConfigMaps (see ADR-005 and ARCHITECTURE.md §7.3).

### 8.2 Operator instance per Auth instance

The upstream OSS Operator is designed to manage one PowerDNS Authoritative Server instance. For multi-instance deployments, a separate Operator instance is required per Auth instance. The CRD scope (namespace vs. cluster) determines which Operator instance handles a given CR.

### 8.3 No drift detection

The Operator reconciles only on Kubernetes watch events. If the Auth state is modified directly via the PowerDNS HTTP API (port 8081) or via the Web UI, the divergence will not be corrected until the next CRD event. This is a known limitation of the upstream Operator and must be addressed in operational procedures (see ADR-005).

### 8.4 Record name validation

The Operator does not enforce that `metadata.name` is a subdomain of the referenced zone. PowerDNS will reject such records at the API level, and the Operator will reflect the failure in `status.conditions`. Cluster-wide admission validation (e.g., via a validating webhook) may be added in a future scope.

### 8.5 Open points

| # | Open point | Impact |
|---|---|---|
| OP-1 | Are `ClusterZone` / `ClusterRRset` in scope for the initial Alpha, or only namespace-scoped types? | Determines which CRDs are installed and reconciled |
| OP-2 | Which additional record types beyond the base scope (A, AAAA, CNAME, MX, TXT) are required? | Determines implementation scope |
| OP-3 | Is `spec.catalog` required for the initial scope? | Relevant only if secondary/AXFR replication is planned |
| OP-4 | Should a validating admission webhook be added to enforce zone–record name consistency? | Determines whether extra admission control infrastructure is needed |
