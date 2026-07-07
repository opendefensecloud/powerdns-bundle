# Update and Upgrade Guide

This guide describes how the PowerDNS OCM bundle is versioned and how to update
or upgrade a running deployment. It is the single source of truth for the update
procedure; the [air-gap deployment guide](AIR-GAP-DEPLOYMENT.md) covers only the
air-gap-specific deltas and links here for the full process.

## Contents

1. [Versioning strategy](#1-versioning-strategy)
2. [OCM-native update process](#2-ocm-native-update-process)
3. [Integrity and provenance](#3-integrity-and-provenance)
4. [CRD versioning and migration concept](#4-crd-versioning-and-migration-concept)
5. [Rollback](#5-rollback)
6. [Scope and impact of manual steps](#6-scope-and-impact-of-manual-steps)
7. [Upgrade validation](#7-upgrade-validation)
8. [Reference upgrade in a test environment](#8-reference-upgrade-in-a-test-environment)

---

## 1 Versioning strategy

The OCM component carries its own version, **independent of the upstream image
versions it bundles**. The component version describes the *tested integration
contract* — the specific set of images, manifests, and KRO blueprints validated
together — not merely a wrapper tag.

| Version | Owner | Meaning |
|---|---|---|
| Component `version` (`github.com/bwi/powerdns-ocm:<version>`) | This project | Version of the tested bundle / integration set. |
| Image resource `version` (e.g. `pdns-authoritative 4.9.16`) | Upstream projects | Upstream artifact version, tracked as released. |
| `directory` resource `version` (deploy + KRO manifests) | This project | Tracks the component version. |

The component version follows [Semantic Versioning](https://semver.org/):

| Increment | When |
|---|---|
| **MAJOR** | Breaking CRD/API changes; mandatory manual migration; incompatible persistent-data (LMDB / zone) format changes; any upgrade that is **not** cleanly rollbackable. |
| **MINOR** | New component or feature added in a backwards-compatible way (e.g. enabling the multi-instance Garage path, adding the optional web UI slot). |
| **PATCH** | Backwards-compatible image bumps and manifest fixes that require no manual action. |

The current PoC version is `0.1.0-poc`. The `-poc` pre-release suffix is dropped
to a stable `0.1.0` (and later `1.0.0` at GA) once the package is feature-frozen.

> An image bump may ship in a PATCH release **only** when it is expected to be
> backwards-compatible. An image upgrade that changes CRD schemas, persistent-data
> formats, or requires manual steps forces at least a MINOR or MAJOR bump.

To change the version, update **all** of these in lock-step:

- `version:` in `ocm/component-descriptor.yaml`,
- the two `directory` resource `version` fields in the same file,
- `COMPONENT_VERSION` in the `Makefile`, and
- the `app.kubernetes.io/version` label on the KRO `ResourceGraphDefinition`
  (`deploy/kro/powerdns-instance-rgd.yaml`).

---

## 2 OCM-native update process

OCM publishing and Kubernetes deployment are **two separate phases**. Building,
bundling, and pushing the OCM component publishes the package to a registry; it
does **not** change anything running in the cluster until the manifests are
applied. In air-gap mode, pushing the OCM component to an OCI registry does not
rewrite the Kubernetes image references either — image localization remains a
separate step (see [§6](#6-scope-and-impact-of-manual-steps)).

### 2.1 Publish phase

1. Bump the component `version` and update image tags in
   `ocm/component-descriptor.yaml` as required (see [§1](#1-versioning-strategy)).
2. Update `COMPONENT_VERSION` in the `Makefile` to match.
3. Build and validate the component archive:
   ```sh
   make ocm-build
   make ocm-validate
   ```
4. Bundle the images into the archive for transport:
   ```sh
   make ocm-bundle
   ```
5. Publish:
   - **Online:** `make ocm-push REGISTRY=<oci-registry>`.
   - **Air-gap:** transfer `ocm/ctf-bundled.tar` and push to the private
     registry as described in the [air-gap guide](AIR-GAP-DEPLOYMENT.md).

Multiple component versions can coexist in a registry, which is what makes
version-pinned rollback possible (see [§5](#5-rollback)).

### 2.2 Deploy phase

1. **Air-gap only:** re-run image localization if any image tags changed:
   ```sh
   ./hack/localize-images.sh --registry <registry>
   ```
2. If CRDs changed, apply them **before** the operator rolls out — see
   [§4](#4-crd-versioning-and-migration-concept).
3. Apply the updated manifests:
   - **Online:** `kubectl apply -k deploy/`
   - **Air-gap:** `kubectl apply -k deploy/overlays/air-gap/`
4. Kubernetes performs rolling updates automatically per the strategy in
   [`ARCHITECTURE.md` §8.3](ARCHITECTURE.md#83-rolling-updates). The
   Authoritative Server uses `Recreate` and incurs brief downtime.
5. Validate the upgrade — see [§7](#7-upgrade-validation).

---

## 3 Integrity and provenance

All shipped container images are pinned by immutable digest
(`repo:tag@sha256:...`) across the component descriptor, the base deployment
manifests, and the KRO resource graph definition. The tag is retained for
readability while the digest guarantees that every environment pulls the exact
same image content. The air-gap overlay rewrites only the registry/name, so the
pinned tag and digest are preserved when deploying from a private mirror.

The build also generates OCM resource digests (`OCM_ADD_FLAGS` no longer carries
`--skip-digest-generation`), so the component version embeds content digests for
every resource.

For production / GA, harden provenance further by:

- verifying component digests after push / transfer, and
- optionally signing component versions according to the target platform's OCM
  policy.

After publishing, add a verification step: inspect the component version in the
target registry and confirm the resource references and digests match the source
bundle.

---

## 4 CRD versioning and migration concept

The four CRDs (`Zone`, `ClusterZone`, `RRset`, `ClusterRRset`) are **owned by the
upstream PowerDNS Operator**, not authored by this project. We vendor the operator
image and ship the CRD manifests as delivered upstream. The current served and
stored API version is `dns.cav.enablers.ob/v1alpha2`.

Custom Resource conversion between API versions is performed by the **Kubernetes
API server** (via the CRD's `conversion` strategy), not automatically by the
operator. A conversion webhook only exists if the upstream operator ships one.
**Do not assume automatic conversion is available** unless an upstream conversion
webhook is confirmed.

When an upstream operator release introduces a new CRD API version:

1. Review the upstream release notes and the CRD diff.
2. Apply the updated CRD manifests **before** rolling out the new operator.
3. Keep the old and new versions both `served: true` for the duration of the
   transition.
4. If the schemas are incompatible, migration requires either an
   upstream-supported conversion webhook or an explicit rewrite of existing
   objects.
5. Migrate stored objects to the new storage version by re-writing each CR, for
   example:
   ```sh
   kubectl get zones,rrsets -A -o yaml | kubectl apply -f -
   ```
6. Remove the old served version **only** after it no longer appears in the
   CRD's stored versions:
   ```sh
   kubectl get crd zones.dns.cav.enablers.ob \
     -o jsonpath='{.status.storedVersions}'
   ```

Because we do not control the CRD schemas, the "if schema changes occur" clause
is gated entirely on upstream operator upgrades. As long as the bundled operator
stays on `v1alpha2`, no CRD migration is required.

---

## 5 Rollback

Because a registry can hold multiple component versions, a rollback redeploys the
manifests and images of the previous component version. **Rollback is safe only
when all of the following hold:**

- the CRD schema and stored version were not migrated incompatibly,
- the persistent data format (LMDB / zone data) is still compatible,
- the previous images are still present in the (private) registry, and
- the KRO `ResourceGraphDefinition` changes are backwards-compatible.

For an upgrade that included a CRD storage migration or a persistent-data format
change, rollback is **not** a simple redeploy: it requires a backup / restore or
a dedicated downgrade procedure. Take the backups described in
[§6](#6-scope-and-impact-of-manual-steps) before any such upgrade.

---

## 6 Scope and impact of manual steps

| Step | Manual / Automated | Impact |
|---|---|---|
| Edit `component-descriptor.yaml` + `Makefile` version / tags | Manual | Source of the upgrade; no runtime impact until applied. |
| `make ocm-build` / `ocm-bundle` / `ocm-push` | Manual (CLI / CI) | Publishes the package; no runtime impact. |
| Air-gap transfer + push to private registry | Manual | Required before deploy in air-gap; needs registry credentials. |
| `hack/localize-images.sh` (air-gap) | Manual | Rewrites image references; must run if tags changed. |
| Apply CRD manifests | Manual, ordered | Cluster-scoped; must precede the operator rollout. |
| `kubectl apply -k …` | Manual (or GitOps) | Triggers rollouts. |
| Pod rolling update | Automated (Kubernetes) | Per `ARCHITECTURE.md` §8.3. |

**Pre-upgrade backups (manual, recommended):**

- Export existing CRs before any CRD upgrade:
  ```sh
  kubectl get clusterzones,zones,clusterrrsets,rrsets -A -o yaml > cr-backup.yaml
  ```
- Snapshot the Authoritative Server PVC / LMDB (and the Lightning Stream / S3
  snapshots in multi-instance mode) before an authoritative-server upgrade.

**Blast radius and runtime impact:**

- CRDs and the KRO `ResourceGraphDefinition` are **cluster-scoped** and affect
  **all** PowerDNS instances, not a single namespace.
- An operator rollout may briefly pause CR reconciliation.
- The Authoritative Server uses the `Recreate` strategy (ReadWriteOnce PVC),
  causing brief authoritative DNS / API downtime during its upgrade.
- Recursor and dnsdist rolling updates may reset in-memory caches and open
  connections.
- Air-gap upgrades additionally require registry push, image localization,
  `imagePullSecrets` / credentials, and verification that no external image
  references remain.

---

## 7 Upgrade validation

After applying an update, confirm the system is healthy:

```sh
# Rollouts completed
kubectl -n dns rollout status deployment/dnsdist
kubectl -n dns rollout status deployment/pdns-recursor
kubectl -n dns rollout status deployment/pdns-auth
kubectl -n dns rollout status deployment/pdns-operator

# CRDs present and (after CRD changes) stored version as expected
kubectl get crd | grep dns.cav.enablers.ob
kubectl get crd zones.dns.cav.enablers.ob -o jsonpath='{.status.storedVersions}'

# Custom resources still reconcile
kubectl get clusterzones,zones,clusterrrsets,rrsets -A

# Images match the intended registry / version
kubectl -n dns get deploy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
```

Finish with a DNS smoke test through the dnsdist → recursor / authoritative path
(the `hack/validate-*.sh` scripts cover these checks).

---

## 8 Reference upgrade in a test environment

The reference upgrade is **automated** as a dedicated CI job (`upgrade-smoke`)
that exercises an OCM-native version upgrade end-to-end against the live test
cluster. It is opt-in: it runs on a pull request when the repository variable
`RUN_UPGRADE_SMOKE` is set to `true`, or on demand via the manual
`run_upgrade` workflow input.

### 8.1 What the job does

1. **Builds two OCM packages** in isolated workspaces (`hack/build-upgrade-packages.sh`):
   - a **baseline** — a synthetic *previous* release (component `0.1.0-poc`,
     authoritative image `4.9.14`), and
   - a **candidate** — the upgrade target (component `0.1.1-poc`,
     authoritative image `4.9.16`).

   Each package is published as a CI artifact (`ocm-upgrade-packages`) for
   inspection and provenance. The deploy tree carried by each package is then
   extracted with `ocm download resources --downloader ocm/dirtree`, so the
   upgrade is driven by **what the package actually ships**, not the source tree.

2. **Performs the upgrade and verifies continuity** (`hack/validate-upgrade.sh`):
   - deploys the baseline package and waits for a healthy rollout;
   - seeds two independent pieces of state — an operator-managed `Zone` custom
     resource, **and** an LMDB-native sentinel zone/record written through the
     Authoritative Server's own HTTP API (the only valid LMDB writer when
     Lightning Stream mode holds the store under external locking). The sentinel
     is **not** backed by any custom resource, so the operator cannot recreate
     it and its survival demonstrates that the DNS data store carried over the
     upgrade rather than operator re-reconciliation;
   - applies the candidate package and waits for the new rollout;
   - asserts the upgrade actually happened and data survived:
     - the running authoritative image is exactly the candidate image,
     - the Deployment pod was replaced (pod UID changed),
     - the PVC bound the **same** underlying volume (`.spec.volumeName`
       unchanged — no data-losing re-provision),
     - `observedGeneration >= generation` on the workload,
     - the LMDB-native sentinel zone/record is still present after the upgrade.

3. **Restores a known-good state.** A finalize step always re-applies the
   candidate so a mid-run failure can never leave the namespace downgraded on
   the baseline image. Diagnostics (events, describe, logs) are captured on
   failure.

### 8.2 Scope and limitations

- The baseline is a **synthetic** previous release (no prior published artifact
  exists yet). Once a real prior version has been released to the registry, the
  baseline should be pulled from there instead of rebuilt locally.
- The job exercises the single-instance authoritative stack (namespace + base
  overlay). The KRO resource-graph overlay is intentionally out of scope for
  this first iteration.
- The job is **upgrade-only**; an automated rollback test is a planned
  follow-up (see §5 for the rollback procedure and its preconditions).

### 8.3 Evidence captured per run

- the baseline and candidate component/image versions (job summary),
- `kubectl rollout status` for the authoritative Deployment,
- the resolved running image before and after,
- the PVC volume binding before and after, and
- the LMDB-native sentinel survival check.
