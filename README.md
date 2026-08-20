# PowerDNS OCM

[![CI](https://github.com/telekom/odc-powerdns-bundle-dev/actions/workflows/ci.yml/badge.svg)](https://github.com/telekom/odc-powerdns-bundle-dev/actions/workflows/ci.yml)

An [Open Component Model (OCM)](https://ocm.software/) package that deploys and operates a production-grade DNS infrastructure on Kubernetes, built around [PowerDNS](https://www.powerdns.com/).

The bundle integrates:

- **dnsdist** — DNS frontend, traffic steering and load balancing
- **PowerDNS Recursor** — caching and recursive resolution
- **PowerDNS Authoritative Server** — authoritative zone data, backed by LMDB
- **LightningStream + Garage** — LMDB replication and backup across instances
- **Kubernetes Operator / Controller** — lifecycle management via Custom Resources

## Requirements

- Kubernetes 1.27+
- [OCM CLI](https://ocm.software/docs/getting-started/installing-ocm-cli/)
- [KRO](https://kro.run/) (Kubernetes Resource Operator) for resource composition

## Installation

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for a step-by-step guide covering single-instance, multi-instance, and air-gap deployments.

## Documentation

| Document | Description |
|---|---|
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | Step-by-step installation guide (KRO-based, single- and multi-instance) |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2 operations: monitoring, troubleshooting, scaling, backup, updates |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Component architecture and design decisions |
| [docs/CRD-SPECIFICATION.md](docs/CRD-SPECIFICATION.md) | Custom Resource API reference (Zone, ClusterZone, RRset, ClusterRRset) |
| [docs/UPGRADE.md](docs/UPGRADE.md) | Version upgrade and rollback procedures |
| [docs/AIR-GAP-DEPLOYMENT.md](docs/AIR-GAP-DEPLOYMENT.md) | Air-gap bundling and offline deployment |
| [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) | Prometheus endpoints, discovery, metrics catalogue, and validation |
| [docs/CI-CD.md](docs/CI-CD.md) | CI/CD workflow, artifacts, and repository settings |
| [CHANGELOG.md](CHANGELOG.md) | Release and delivery history |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |

## License

Apache License 2.0 — see [LICENSE](LICENSE).
