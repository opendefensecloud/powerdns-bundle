# ADR-007 - Defer Full OpenTelemetry Integration

**Status:** Accepted

## Context

The bundle must expose operational metrics and evaluate broader OpenTelemetry
integration. Recursor and Authoritative Server already provide native
Prometheus endpoints, while the Operator exposes controller-runtime metrics.

OpenTelemetry could add a collector-based telemetry pipeline, unified export
to an OTLP backend, and application tracing. However, the current components do
not provide a shared trace context across the UDP/TCP DNS request path.
The delivered Recursor version `5.2.11` also predates the Recursor's
OpenTelemetry trace-condition support introduced in later releases.
Introducing a collector also adds another image, configuration lifecycle,
resource budget, security surface, and backend-specific commissioning work.

## Decision

Use the native Prometheus endpoints as the delivered observability baseline.
Do not deploy an OpenTelemetry Collector or add application instrumentation in
the current scope.

When separately commissioned, an OpenTelemetry Collector may scrape the
existing endpoints with the Prometheus receiver and export metrics through
OTLP. Logs may be collected through the platform's standard Kubernetes log
pipeline. Distributed tracing requires a separate design because DNS clients
do not propagate the HTTP-style trace context needed to correlate requests
across dnsdist, Recursor, Authoritative Server, and Operator reconciliation.

## Consequences

- The required metrics are available without adding a telemetry runtime.
- Existing Prometheus installations can scrape the Services directly.
- An OpenTelemetry metrics pipeline can be added later without workload
  changes.
- Full request tracing is not delivered and needs separate commissioning,
  capacity planning, sampling, data-protection review, and backend selection.
- Alerting rules and dashboards remain platform-specific and are not installed
  by this bundle.
