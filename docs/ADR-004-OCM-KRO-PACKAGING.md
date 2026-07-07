# ADR-004 — OCM + KRO for Packaging and Instantiation

**Status:** Accepted

## Context

The target platform mandates the use of OCM (Open Component Model) as the package format and KRO (Kubernetes Resource Operator) as the instantiation mechanism. The solution must support multiple autonomous DNS instances per Kubernetes cluster, each independently configurable, and must support OCM-native upgrades.

## Decision

Package the entire DNS solution as an **OCM Component** and use **KRO ResourceGraphDefinitions** for dependency-aware instantiation of all Kubernetes resources.

- The OCM Component Descriptor lists all included components (dnsdist, Recursor, Authoritative Server, data store, replication components, network exposure, Operator, CRDs) with explicit version references.
- KRO ResourceGraphDefinitions model the dependency graph between Kubernetes resources, ensuring correct creation and deletion order.
- Each DNS instance is instantiated via KRO + OCM, enabling namespace-level isolation and independent lifecycle management.

## Consequences

- Instantiation, upgrade, and teardown of complete DNS instances are handled by KRO + OCM without manual resource management.
- Multi-instance operation is a natural consequence: each KRO instance manages its own resource graph independently.
- OCM-native versioning enables controlled upgrades with rollback capability.
- The solution is tightly coupled to the target platform's Blueprint feature set; deploying outside this context requires adaptation.
- CRD schema migrations must be planned as part of OCM package version upgrades to avoid data loss.
