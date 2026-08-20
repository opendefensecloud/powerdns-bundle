# Observability

The bundle exposes native Prometheus metrics from the PowerDNS Recursor,
PowerDNS Authoritative Server, and PowerDNS Operator. No monitoring backend is
installed by the bundle.

## Scrape targets

| Component | Kubernetes Service | Port | Path | Metric families |
|---|---|---:|---|---|
| Recursor | `pdns-recursor` | `8082` (`metrics`) | `/metrics` | `pdns_recursor_*` |
| Authoritative Server | `pdns-auth` | `8081` (`api`) | `/metrics` | `pdns_auth_*` |
| Operator | `pdns-operator-metrics` | `8080` (`metrics`) | `/metrics` | `controller_runtime_*`, `workqueue_*`, `rest_client_*`, `process_*`, `go_*` |

The Services are `ClusterIP` resources. Metrics are reachable only from
networks that can access the cluster Service network unless operators
deliberately expose them.

The PowerDNS webservers can expose operationally sensitive statistics in
addition to `/metrics`. Production deployments should restrict access with
NetworkPolicies and component ACLs rather than exposing
these ports outside the monitoring path.

All three Services carry these annotations:

```yaml
prometheus.io/scrape: "true"
prometheus.io/path: /metrics
prometheus.io/port: "<component port>"
```

Prometheus installations using annotation-based Kubernetes service discovery
can therefore scrape the default deployment and KRO-created instances without
installing additional CRDs.

## Prometheus Operator

Clusters with the Prometheus Operator CRDs can deploy the base stack and three
`ServiceMonitor` resources with:

```bash
kubectl apply -k deploy/overlays/monitoring
```

The overlay intentionally remains separate from `deploy/` because Kubernetes
rejects `ServiceMonitor` objects when the `monitoring.coreos.com` CRDs are not
installed. If the cluster's Prometheus resource selects ServiceMonitors by
label, add the required environment-specific label to the objects in
`deploy/overlays/monitoring/service-monitors.yaml`.

KRO-created instances use arbitrary namespaces and are discovered through
their Service annotations. A platform-specific ServiceMonitor may instead
select the same Service labels across the desired namespaces.

## Metrics catalogue

PowerDNS and controller-runtime generate the exact metric names from the
running component version and include Prometheus `HELP` and `TYPE` records in
the response. The endpoint output is the authoritative complete catalogue:

```bash
kubectl -n dns port-forward service/pdns-recursor 18082:8082
curl -fsS http://127.0.0.1:18082/metrics

kubectl -n dns port-forward service/pdns-auth 18081:8081
curl -fsS http://127.0.0.1:18081/metrics

kubectl -n dns port-forward service/pdns-operator-metrics 18080:8080
curl -fsS http://127.0.0.1:18080/metrics
```

The stable families and their operational meaning are:

| Family | Description |
|---|---|
| `pdns_recursor_*` | Recursor questions and answers, response codes, cache hits and misses, cache sizes, outgoing queries, latency, throttling, resource limits, and DNSSEC processing |
| `pdns_auth_*` | Authoritative UDP/TCP queries and answers, response and error counts, latency, packet/cache behaviour, backend activity, DNS update processing, and DNSSEC/signing state |
| `controller_runtime_*` | Reconciliation totals, reconciliation errors, active workers, webhook activity, and controller-runtime internals |
| `workqueue_*` | Queue depth, additions, processing duration, unfinished work, and longest-running work item |
| `rest_client_*` | Kubernetes API request counts, response codes, request latency, and rate-limiter behaviour |
| `process_*` | Operator process CPU, memory, file-descriptor, and start-time information |
| `go_*` | Go runtime garbage collection, goroutines, memory allocation, and scheduler information |

Metric names can be added, removed, or renamed by component upgrades. Dashboards
and alerts should use the `HELP` text and current endpoint output as their
version-specific reference rather than assuming that every series exists in
all supported versions.

PowerDNS references:

- [Recursor Prometheus endpoint](https://doc.powerdns.com/recursor/http-api/prometheus.html)
- [Authoritative Server metrics endpoint](https://doc.powerdns.com/authoritative/http-api/index.html#metrics-endpoint)

## Suggested minimum monitoring

Monitor at least:

- DNS query and answer rates by transport and response code
- `SERVFAIL` and other error responses
- Recursor and Authoritative latency
- Recursor packet/cache behaviour and cache size
- Operator reconciliation errors and workqueue backlog
- Scrape target availability with Prometheus `up`
- Process CPU, memory, and file-descriptor saturation

## Validation

Static manifest coverage runs in every CI execution:

```bash
bash hack/validate-observability-manifests.sh
```

The live validation port-forwards all three Services and checks their
Prometheus output. It then requires the three ServiceMonitor resources, checks
the CI Prometheus API, and confirms that `pdns-recursor`, `pdns-auth`, and
`pdns-operator-metrics` are active targets with `health=up`:

```bash
NAMESPACE=dns bash hack/validate-observability.sh
```

It is also part of `hack/validate-cluster.sh` under the `observability` suite.
When that suite is selected, CI installs Prometheus Operator `v0.91.0` if its
CRDs are absent, deploys the packaged ServiceMonitors, and creates the
Prometheus instance defined in `hack/ci/prometheus.yaml`. That instance runs in
a dedicated `monitoring` namespace (labelled `network-policy/monitoring: "true"`
so the workload network policies admit its scrapes) and discovers the
ServiceMonitors in the `dns` namespace across the namespace boundary.
The Prometheus instance is for verification only and is not part of the
delivered runtime stack.

## OpenTelemetry

The OpenTelemetry decision and integration boundary are documented in
[ADR-007](ADR-007-OPENTELEMETRY-INTEGRATION.md). Native Prometheus metrics are
the implemented baseline. A collector can ingest these endpoints later
through its Prometheus receiver without changing the workloads.
