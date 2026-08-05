# Air-Gap Deployment

This document describes how to install and operate the PowerDNS OCM solution in an environment that has no outbound internet access. All container images travel inside the OCM bundle; the target cluster never contacts an external registry.

## Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `ocm` CLI | 0.11.0 | Build, transfer, and inspect OCM component archives |
| `kubectl` | 1.28 | Apply Kubernetes manifests |
| `kustomize` (or `kubectl apply -k`) | 5.x | Render overlays |
| Writable OCI registry in the target environment | — | Serve images to cluster nodes |

The OCM CLI is available at <https://ocm.software/docs/getting-started/>.

## Two independent localization mechanisms

Image-reference "localization" (rewriting a registry address to a private one) is handled by
**two separate, independent mechanisms** in this repository. They are not layered on top of each
other and neither depends on the other; which one applies depends on how you deploy:

| Mechanism | File | Consumed by | Covers |
|---|---|---|---|
| OCM-native declarative localization | `ocm/localization-config.yaml` | OCM-aware deployers that instantiate the component version directly (e.g. the OCM Flux plugin, the OCM Add-on Manager, `ocm` CLI localization commands) — **not** used by the `kubectl`/`kustomize` procedure below | Plain, YAML-path addressable image references inside `deploy/base/**/*.yaml` |
| Script-based localization (this guide) | `hack/localize-images.sh` | Anyone deploying with plain `kubectl apply -k` (Steps 1–5 below) | Every bundled image, including the multi-instance KRO `ResourceGraphDefinition` (`deploy/kro/powerdns-instance-rgd.yaml`), whose image references are literal strings that the declarative OCM mechanism cannot address |

**Important:** `ocm/localization-config.yaml`'s `kind: LocalizationConfig` is a plain **OCM CLI
configuration object** (part of the Open Component Model specification, `apiVersion:
config.ocm.software/v1alpha1`). It is **not a Kubernetes object**, is **never applied to a
cluster** with `kubectl`, and has **no relation** to this project's own Kubernetes CRDs (`Zone`,
`ClusterZone`, `RRset`, `ClusterRRset` — defined under `deploy/base/crds/` and reconciled by the
PowerDNS Operator). The shared word "Localization" is coincidental terminology from two unrelated
domains (OCM image-reference rewriting vs. this project's DNS zone/record custom resources).

This guide documents the **script-based path** (`hack/localize-images.sh`), since it is the one
required for the plain `kubectl`/`kustomize` deployment procedure below and is the only one of the
two that also covers the multi-instance KRO manifests.

## Step 1 — Build the OCM bundle (internet-connected machine)

Run the following on a machine that can reach the upstream container registries:

```bash
make ocm-bundle
```

This executes two steps internally:

1. `ocm add componentversions` — builds `ocm/ctf.tar` from the component descriptor with external image references.
2. `ocm transfer commontransportarchive --copy-resources` — copies every referenced image as a local blob into `ocm/ctf-bundled.tar`.

The resulting `ocm/ctf-bundled.tar` is a self-contained transport archive that embeds every bundled container image — the DNS components (dnsdist, pdns-recursor, pdns-auth, lightningstream), the operator, and the multi-instance images (Garage and its bootstrap helper) — plus the Kubernetes manifests.

## Step 2 — Transfer the bundle to the air-gapped environment

Copy `ocm/ctf-bundled.tar` to the air-gapped environment using whatever transfer mechanism is available (USB, internal artifact store, secure file transfer):

```bash
scp ocm/ctf-bundled.tar user@jump-host:/staging/
```

## Step 3 — Push images to the private registry

On the air-gapped machine (or a machine with access to both the bundle and the private registry), push the bundled images:

```bash
OCM_BIN=ocm
REGISTRY=harbor.example.com/powerdns-ocm    # replace with your registry

${OCM_BIN} transfer commontransportarchive ocm/ctf-bundled.tar oci://${REGISTRY}
```

This populates the registry with all component images under the specified prefix. Alternatively, use the `make ocm-push` target after setting the `REGISTRY` variable:

```bash
make ocm-push REGISTRY=harbor.example.com/powerdns-ocm
```

To verify the images are present in the registry after the push:

```bash
${OCM_BIN} get componentversion --repo oci://${REGISTRY} github.com/bwi/powerdns-ocm
```

## Step 4 — Configure image references

Generate the air-gap Kustomize overlay with your registry address:

```bash
./hack/localize-images.sh --registry harbor.example.com/powerdns-ocm
```

The image set is derived from the OCM component descriptor, so this covers every bundled image (the DNS components, the operator, and the multi-instance Garage images). The command rewrites **both** deploy paths: it regenerates `deploy/overlays/air-gap/kustomization.yaml` for the single-instance base, and rewrites the multi-instance KRO ResourceGraphDefinition (`deploy/kro/powerdns-instance-rgd.yaml`) in place. It is idempotent — re-running it, or running it again with a different registry, always converges to the chosen registry. Inspect the result:

```bash
kubectl kustomize deploy/overlays/air-gap/
grep -nE '^[[:space:]]*image:' deploy/kro/powerdns-instance-rgd.yaml
```

Confirm that every `image:` line refers exclusively to your private registry and contains no reference to `docker.io`, `registry-1.docker.io`, or `ghcr.io`.

For the single-instance base you may instead edit the `newName` values in `deploy/overlays/air-gap/kustomization.yaml` directly — but manual edits do **not** cover the multi-instance KRO path, so prefer the script if you deploy multi-instance.

## Step 5 — Deploy

```bash
kubectl apply -k deploy/overlays/air-gap/
```

Kubernetes will pull all images from your private registry. No outbound internet connection is required after this point.

To confirm all pods are running:

```bash
kubectl -n dns get pods
```

Expected output (all containers `Running`, `READY 1/1`):

```
NAME                           READY   STATUS    RESTARTS   AGE
dnsdist-<hash>                 1/1     Running   0          60s
pdns-auth-<hash>               2/2     Running   0          60s
pdns-recursor-<hash>           1/1     Running   0          60s
```

## Step 6 — Verify no external registry access

Confirm that no image pull from an external registry occurred during deployment. On each cluster node, inspect the container runtime log or use `crictl` / `ctr`:

```bash
# containerd (typical on Kubernetes nodes)
crictl images | grep -v harbor.example.com
```

The output should be empty (no images from external registries). Alternatively, examine pod events:

```bash
kubectl -n dns describe pods | grep -i "pulled\|pulling"
```

All `Pulled` events should reference your private registry only.

## Image reference table

The following table lists every image bundled in the OCM package and its expected reference after localization.

| Component | Upstream image | Localized as (example) |
|-----------|---------------|------------------------|
| dnsdist | `powerdns/dnsdist-19:1.9.15` | `<registry>/powerdns/dnsdist-19:1.9.15` |
| pdns-recursor | `powerdns/pdns-recursor-52:5.2.11` | `<registry>/powerdns/pdns-recursor-52:5.2.11` |
| pdns-auth | `powerdns/pdns-auth-49:4.9.16` | `<registry>/powerdns/pdns-auth-49:4.9.16` |
| lightningstream | `powerdns/lightningstream:1.0.0` | `<registry>/powerdns/lightningstream:1.0.0` |
| garage (multi-instance only) | `dxflrs/garage:v1.0.1` | `<registry>/dxflrs/garage:v1.0.1` |

`<registry>` is the value passed to `--registry` in Step 4. Garage is reserved in the OCM descriptor for multi-instance operation and is not deployed in the PoC; its localization entry is included for completeness.

## Updating to a new version

See the [Update and Upgrade Guide](UPGRADE.md) for the full versioning strategy,
OCM update process, CRD migration concept, rollback, and validation steps.

Air-gap-specific reminders when upgrading:

1. Rebuild and re-bundle on the internet-connected machine: `make ocm-bundle`.
2. Transfer the new `ocm/ctf-bundled.tar` and push the images to the private
   registry (Steps 2–3 above).
3. Re-run `hack/localize-images.sh --registry <registry>` if any image tags
   changed.
4. Apply: `kubectl apply -k deploy/overlays/air-gap/`; Kubernetes performs the
   rolling update automatically.
5. Verify no external registry pulls occur (Step 6 above).
