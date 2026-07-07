# Changelog

All notable changes are documented here.
Headlines are timestamped milestones in the form `yyyy-mm-dd — Milestone n`.
Sections within each milestone use `Additions`, `Changes`, and `Fixes`.

---

## 2026-07-7 - v0.1.0

### Additions

- Document end-to-end installation test in a fully air-gapped cluster in `docs/AIR-GAP-DEPLOYMENT.md`; requires a dedicated isolated environment

---

## 2026-07-01 — Milestone 3

### Additions

- Complete documentation set: installation guide, CRD configuration reference, operations manual, architecture documentation, upgrade guide, ADR index (`docs/`)
- OCM package update/upgrade capability: SemVer versioning strategy, OCM-native upgrade procedure, automated `upgrade-smoke` CI job including rollback and data-continuity assertions (`docs/UPGRADE.md`)
- Rolling update configuration: `RollingUpdate` (maxSurge: 1, maxUnavailable: 0) for dnsdist, Recursor, and Operator; `Recreate` for Authoritative Server (ReadWriteOnce PVC constraint); mirrored in KRO `ResourceGraphDefinition`
- Security hardening: Pod Security Standards (Baseline enforced, Restricted audited/warned), non-root containers, read-only root filesystems, capability drops, `seccompProfile: RuntimeDefault`, image digest pinning across all manifests and the OCM descriptor
- Network Policies: default-deny (ingress + egress) baseline with per-component allow-lists; metrics ingress scoped to namespaces labelled `network-policy/monitoring: "true"`; enforcement validated by `hack/validate-network-policies.sh`
- DNS abuse mitigation in dnsdist: corrected QPS rate-limit rule (was inverted), UDP ANY truncation for anti-amplification, configurable per-client rate limit (`DNSDIST_MAX_QPS`, `DNSDIST_MAX_QPS_PER_CLIENT`)
- CVE scanning via Trivy: SARIF upload to code-scanning tab, blocking gate on HIGH/CRITICAL findings, per-image CycloneDX SBOMs via Syft, time-boxed `.trivyignore.yaml` allowlist with expiry dates
- CI/CD pipeline hardened: branch protection with required reviewers and four required status checks, job-level `timeout-minutes`, PR concurrency cancellation, composite action for cluster authentication
- CI/CD portability to customer GitHub Actions environment: EKS OIDC authentication mode, no hardcoded internal references, all prerequisites documented (`docs/CI-CD.md`)
- Prometheus metrics validated end-to-end in CI: ServiceMonitors deployed against a CI-only Prometheus instance; `hack/validate-observability.sh` verifies all three scrape targets report `health=up`; optional `deploy/overlays/monitoring/` ServiceMonitor overlay for Prometheus Operator
- Optional web UI assessment: PowerDNS-Admin documented as reference candidate; integration prerequisites, example manifests, and estimated effort in `docs/WEBUI.md`; OCM Component Descriptor reserves a commented-out UI slot; no architectural blocker identified
- Air-gap localization extended to all deployed images on both single-instance (Kustomize overlay) and KRO multi-instance (in-place `ResourceGraphDefinition`) deploy paths; `hack/validate-air-gap-localization.sh` CI gate ensures no image escapes to a public registry
- OSS compliance verification: all delivered images confirmed as public OSS upstreams; source and per-image SBOMs; OSS-only GitHub Actions check (`hack/validate-github-actions.sh`); secret scanning via gitleaks

### Changes

- Container images updated to clear base-image CVEs: `pdns-recursor` 5.2.9 → 5.2.11, `lightningstream` 0.6.0 → 1.0.0, `dnsdist` 1.9.14 → 1.9.15, `pdns-auth` 4.9.15 → 4.9.16
- OCM package build enables resource digest generation (previously skipped with `--skip-digest-generation`)
- Config and Secret changes trigger workload rollouts via pod-template checksum annotations instead of unconditional restarts

---

## 2026-06-11 — Milestone 2

### Additions

- Kubernetes CRDs for DNS configuration deployed in-cluster: `Zone`, `ClusterZone`, `RRset`, `ClusterRRset`; supports record types A, AAAA, CNAME, MX, TXT; example manifests in `deploy/examples/`
- Custom Resource status feedback: `status.syncStatus` (Succeeded / Pending / Failed), `status.conditions[]`, and `status.observedGeneration` on all four CRD types; semantics documented in `docs/CRD-SPECIFICATION.md §6`
- Kubernetes Operator (PowerDNS Operator OSS) deployed with RBAC; forked as `ghcr.io/telekom/powerdns-operator` to add `WATCH_NAMESPACE` cache scoping for namespace-level runtime isolation; upstream issue filed at [powerdns-operator/PowerDNS-Operator#307](https://github.com/powerdns-operator/PowerDNS-Operator/issues/307)
- Per-instance operator RBAC: Role/RoleBinding confines zone, rrset, event, and lease writes to the operator's own namespace; slim ClusterRole retains only unavoidable cluster-scoped CRD grants
- KRO `ResourceGraphDefinition` (`PowerDNSInstance` generated CRD): 25 resource templates across 9 dependency layers, CEL-based implicit ordering, `includeWhen` guards for Garage/multi-instance resources, `readyWhen` conditions on all Deployments; versioned in lock-step with the OCM component via `app.kubernetes.io/version`
- Multi-instance operation: namespace-per-instance isolation model; two simultaneous `PowerDNSInstance` stacks validated (29 checks: 29 passed, 0 failed); configurational isolation and independent lifecycle (delete instance A, instance B unaffected) confirmed by `hack/validate-multi-instance.sh`
- LMDB backend for the Authoritative Server: PVC-backed zone store (`pdns-auth-data`, 1 Gi RWO), lightningstream-compatible parameters (`lmdb-lightning-stream=yes`, `lmdb-shards=1`, 1000 MB map size); persistence and pod-restart recovery validated by `hack/validate-lmdb.sh`
- lightningstream sidecar for zone data replication: `type: fs` for single-instance (snapshots on shared PVC); S3 (Garage) backend for multi-instance; recovery validated by `hack/validate-replication.sh`
- Garage single-node S3 store for multi-instance LMDB replication with automated single-node layout, Lightning Stream S3 key, and LMDB bucket bootstrap
- Liveness and Readiness Probes configured on all Deployments (dnsdist, Recursor, Authoritative Server, Operator); negative readiness test validates that an unready pod is removed from Service endpoints

---

## 2026-05-21 — Milestone 1

### Additions

- Public GitHub organization and repositories: `telekom/odc-powerdns-bundle-dev` (private development) and `telekom/odc-powerdns-bundle` (public delivery); Apache 2.0 LICENSE, README, CHANGELOG, CONTRIBUTING
- dnsdist DNS frontend: Kubernetes Deployment with routing rules for recursive queries → Recursor and non-recursive queries → Authoritative backend; LoadBalancer Service on port 53 UDP/TCP
- PowerDNS Recursor: Kubernetes Deployment with configurable upstream resolvers, local zone forwarding to Authoritative Server, and optional pod anti-affinity for HA
- PowerDNS Authoritative Server: Kubernetes Deployment with HTTP API on port 8081, LMDB backend pre-configured, control socket on a writable runtime volume (`readOnlyRootFilesystem: true` compatible)
- Strict architectural separation: Recursor and Authoritative Server run as independent Deployments with no shared functional state; documented with traceability to the applicable regulatory requirement
- CRD schema review and documentation for `Zone`, `ClusterZone`, `RRset`, `ClusterRRset` from PowerDNS Operator OSS, including the `status` section design (`docs/CRD-SPECIFICATION.md`)
- OCM Component Descriptor (`ocm/component-descriptor.yaml`) listing all component images with versions; `make ocm-build` / `make ocm-bundle` two-step packaging workflow; `ocm/localization-config.yaml` for air-gap image substitution
- Deploy-from-package CI job: downloads and checksums the built OCM artifact, extracts manifests via `ocm download`, validates against the source tree, and applies to the reference cluster
- External DNS reachability via LoadBalancer Service on port 53; UDP reachability validated end-to-end from within the cluster VPC
- Air-gap image localization: Kustomize overlay (`deploy/overlays/air-gap/`) and `hack/localize-images.sh` for rewriting all registry references to a customer-provided private registry; `docs/AIR-GAP-DEPLOYMENT.md` with full bundle → transfer → push → localize → deploy → verify procedure
