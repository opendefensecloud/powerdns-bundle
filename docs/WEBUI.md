# Optional Web UI: Installation and Configuration

> **Status:** Optional / deferred  
> **Last updated:** 2026-06-29

A web UI for zone, record, DNSSEC, and user management is **optional** and is **not** part of the default bundle. This guide documents the supported path to install and configure one when it is required. Enabling it is an **additive** change — no core DNS component is modified.

> **Scope note:** Shipping the web UI image and manifests as part of the bundle is a separate change request. The image slot and configuration hooks described below are reserved for that purpose; until they are filled, the steps here describe the intended integration procedure, not a feature that is wired up by default. For the architectural rationale and the concurrent-access decision, see [ARCHITECTURE.md §3.8](ARCHITECTURE.md#38-powerdns-admin--web-ui) and [ADR-005](ADR-005-OPERATOR-CONFIGURATION-PATH.md).

## 1 Candidate selection

| Candidate | License | Maturity | Recommendation |
|---|---|---|---|
| [PowerDNS-Admin](https://github.com/PowerDNS-Admin/PowerDNS-Admin) | MIT | Legacy, maintenance mode | Reference candidate. Feature-complete and widely deployed. |
| [pda-next](https://github.com/PowerDNS-Admin/pda-next) | MIT | Pre-production | Successor; evaluate as it matures. |

Both consume the PowerDNS Authoritative HTTP API and impose no requirement beyond what the platform already exposes. The examples below assume PowerDNS-Admin.

## 2 Prerequisites

| Prerequisite | Status in the platform |
|---|---|
| Authoritative HTTP API reachable on port 8081 | Available (`pdns-auth` Service) |
| Shared API key consumable by the UI | Available (the `pdnsApiKey` value) |
| UI configuration targeting the Auth API | Provided by a new ConfigMap (see §4) |
| Network policy permitting UI → Auth on port 8081 | Provided by a new policy (see §5) |
| External access for the UI (Service / Ingress) | Provided by a new object (see §6) |
| Web UI container image | Bundled via the reserved image slot (see §3) |

## 3 Bundling the image (air-gap)

The Component Descriptor (`ocm/component-descriptor.yaml`) carries a named, commented-out slot for the web UI image. To bundle it:

1. Uncomment the `powerdns-admin` resource in `ocm/component-descriptor.yaml` and pin the image reference and version.
2. Add the matching image-mapping entry to `ocm/localization-config.yaml` so air-gap deployments rewrite the reference to the private registry, exactly as the core component images are handled.
3. Rebuild and transfer the bundle with the existing `make ocm-build` / `make ocm-bundle` targets.

No runtime registry access is introduced — the UI image travels inside the bundle like every other component.

## 4 Enabling and configuring the UI

The deployment blueprint gates optional resources on a schema flag, the same mechanism the multi-instance object store uses. A web UI is enabled by an `enableWebUI` flag that guards a Deployment, a Service, and a ConfigMap in the KRO `ResourceGraphDefinition` (`deploy/kro/powerdns-instance-rgd.yaml`).

Schema flag (per-instance input):

```yaml
spec:
  enableWebUI: true        # default false
```

Configuration ConfigMap — points the UI at the Authoritative API and supplies the shared key:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: powerdns-admin-config
  namespace: <namespace>
data:
  PDNS_API_URL: "http://pdns-auth.<namespace>.svc.cluster.local:8081"
  PDNS_API_KEY: "<pdnsApiKey>"
```

The Deployment mounts this configuration and runs the UI container from the bundled image. Use the shared `pdnsApiKey` secret rather than an inline value in production; reference it via `secretKeyRef` the same way the Operator consumes the key.

## 5 Network policy

Default policies allow only the Operator (and the monitoring namespace) to reach the Auth API on port 8081. Add a policy permitting the UI pod to reach Auth on 8081, following the existing per-component policies under `deploy/base/network-policies/`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: webui-to-auth
  namespace: <namespace>
spec:
  podSelector:
    matchLabels: { app: pdns-auth }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: powerdns-admin }
      ports:
        - protocol: TCP
          port: 8081
```

## 6 External access

Expose the UI Service through an Ingress (or a `LoadBalancer`/`NodePort` Service, per the cluster's ingress strategy). Terminate TLS at the ingress; the UI talks to the Auth API in-cluster over the ClusterIP Service. Do not expose port 8081 of the Auth server externally — the UI is the only intended external consumer of the management API.

## 7 Concurrent-access operational concept

The Operator reconciles CRDs against the same Auth API and does **not** periodically detect drift. If the UI is allowed to write, changes made through it can diverge from the CRD-declared state. Choose one model:

- **Read-only UI (recommended):** the CRD/Operator path stays authoritative; the UI is for inspection only.
- **Temporal separation:** UI writes are permitted only outside windows of Operator-managed change.

See [ADR-005](ADR-005-OPERATOR-CONFIGURATION-PATH.md) for the rationale.

## 8 Verification

1. With `enableWebUI: true`, confirm the UI Deployment, Service, and ConfigMap are created in the target namespace and the pod becomes Ready.
2. From the UI pod, confirm the Auth API answers:
   `curl -H "X-API-Key: <pdnsApiKey>" http://pdns-auth.<namespace>.svc.cluster.local:8081/api/v1/servers/localhost`.
3. Log in to the UI and confirm zones managed via CRDs are listed.
4. Confirm the network policy blocks Auth:8081 from pods other than the Operator, monitoring, and the UI.

For base platform installation, see [INSTALLATION.md](INSTALLATION.md).
