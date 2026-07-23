# Observability — OpenTelemetry

Full OTel signal design for the non-Rails RubyEventStore app
([running-res-without-rails.md](./running-res-without-rails.md)): traces, metrics,
and logs across the three processes, shipped to the Kantox stack (OTel →
VictoriaMetrics / Loki / Grafana, per [infrastructure.md](./infrastructure.md)).

Trace propagation relies on the
[message-metadata-contract.md](./message-metadata-contract.md): `traceparent`
travels in RabbitMQ headers and the Sidekiq payload so one external request is a
single distributed trace end to end.

---

## Topology

Three Rails-free processes, three `service.name`s:

```
RabbitMQ --> [consumer: Kicks] --enqueue--> [worker: Sidekiq] --publish--> EVENT_STORE (Postgres)
   HTTP  --> [web: Puma/Rack]  --command-->  EVENT_STORE --> RES schedules async subscribers (Sidekiq)
```

The whole point of the design: a `traceparent` injected at the edge (HTTP or the
inbound RabbitMQ message) is extracted at every hop, so web → RabbitMQ → Sidekiq →
event handlers is one trace.

## Resource attributes (every signal)

- `service.name` = `<service>-web` | `<service>-consumer` | `<service>-worker`
  (per service; the three processes of one service share the `<service>` stem)
- `service.version` (build revision), `deployment.environment` (staging … prod),
  `cloud.account.id`, `host`, `service.namespace` = the app/bounded context.

## Gems

```ruby
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-instrumentation-sinatra"   # or -rack for a bare Rack app
gem "opentelemetry-instrumentation-rack"
gem "opentelemetry-instrumentation-active_record"
gem "opentelemetry-instrumentation-pg"
gem "opentelemetry-instrumentation-redis"
gem "opentelemetry-instrumentation-net_http"  # HTTParty/Net::HTTP downstreams
gem "opentelemetry-instrumentation-sidekiq"
gem "opentelemetry-instrumentation-bunny"      # RabbitMQ (Kicks uses Bunny)
```

No official Sneakers/Kicks instrumentation → a small manual span wrapper in the
consumer `#work` (see below).

## Signals per component

### Web (Puma + Rack + Sinatra)
- **Traces**: request span (Rack) → controller → command dispatch → DB / cache /
  downstream HTTP child spans.
- **Metrics** (RED + USE): request rate, latency histogram (p50/p95/p99), status
  classes, in-flight requests; Puma pool — busy threads, backlog, worker restarts.
- **Logs**: structured access + errors, correlated by `trace_id`.

### Consumer (Kicks / RabbitMQ) — ingress
- **Traces**: span per consumed message, **context extracted from RabbitMQ
  headers**, then propagated into the enqueued Sidekiq job (the key async link).
- **Metrics**: messages consumed / acked / rejected / requeued, consume latency,
  **queue depth** and **DLX depth**, prefetch utilization, Bunny connection churn.

### Worker (Sidekiq) — event executor
- **Traces**: span per job, continued from the consumer span; child span for
  `EVENT_STORE.publish` and for each async subscriber.
- **Metrics**: jobs enqueued / processed / failed / retried, **job duration**,
  **queue latency** (enqueue→start), queue depth per queue, busy workers, retry
  set + dead set size.

### Event store (RES + Postgres)
- **Traces**: span per `publish`, span per handler invocation.
- **Metrics**: events published **by event type**, handler duration + failure
  rate by handler, **`expected_version` conflict rate** (optimistic-concurrency
  contention), **projection lag** (events behind head).

### Persistence & cache (ActiveRecord/Postgres, Redis)
- **Metrics**: query duration, **connection-pool checkout wait + exhaustion**,
  Redis latency and command counts (bridged from `ActiveSupport::Notifications`).

## Trace-context propagation (the backbone)

Inject on every publish, extract on every consume — the single seam is the
envelope builder from the metadata contract.

```ruby
# publish (RabbitMQ / Sidekiq): inject current context into carrier headers
OpenTelemetry.propagation.inject(headers)

# consume (Kicks #work): continue the trace
context = OpenTelemetry.propagation.extract(headers)
OpenTelemetry::Context.with_current(context) do
  tracer.in_span("consume #{queue}", kind: :consumer) do
    ProcessInboundMessage.perform_async(payload)   # Sidekiq instrumentation carries it on
  end
end
```

- Use **producer/consumer span kinds** + messaging semantic conventions
  (`messaging.system=rabbitmq`, `destination`, `operation`) so Grafana/Tempo draws
  the service graph automatically.
- Use **span links** (not just parent/child) when one job fans out to N events/
  handlers, so the causal graph survives fan-out.
- Promote `correlation_id` / `request_id` / `tenant` to **span attributes** for
  filtering.

## Business / domain telemetry (what dashboards are for)

- Counters by domain outcome (per bounded context): orders placed / paid /
  cancelled, items returned, prices set, etc.
- **Process-manager state transitions** as spans — this app's process managers are
  natural span sources.
- **Freshness gauges**: age of newest event per stream/context — turns "is data
  current?" into an alertable metric.

## Errors

- Record exceptions as **span events** (`exception.*`) so a failed trace shows
  *where* it broke, not just that it did.
- Tag an error taxonomy attribute (validation vs. infra vs. downstream) so
  dashboards separate "user error" from "we broke".

## Logs

- Structured JSON, correlated by `trace_id` / `span_id` (Loki ↔ Tempo/traces
  click-through).
- **Exemplars**: attach trace IDs to latency-histogram buckets so a p99 spike in a
  Grafana panel links straight to an example trace.

## Pipeline (Kantox stack)

- OTLP → **OpenTelemetry Collector** (sidecar on ECS, or the **OTel Operator** +
  Collector CR on EKS — already POC'd at Kantox) → **VictoriaMetrics** (metrics) +
  **Loki** (logs) + traces backend.
- **Grafana** (Okta auth) for dashboards; enable **trace-to-logs** and
  **trace-to-metrics** correlation.
- CloudWatch alarms for ECS/RDS/queue baselines via the infra track
  (`kantox-<service>-<metric>-<environment>`), see infrastructure.md §7–§8.

## What's most often missed (checklist)

- [ ] **Queue-wait vs. processing-time** split (enqueue→start separate from work).
- [ ] **traceparent through RabbitMQ headers AND the Sidekiq payload** — without
      it, traces stop at each process boundary.
- [ ] **Saturation** metrics: DB pool, Sidekiq concurrency slots, RabbitMQ
      prefetch, Redis memory.
- [ ] **`expected_version` conflict rate** + **projection lag** (ES-specific health).
- [ ] **Dead-letter / dead-set** depths.
- [ ] **Data-freshness gauges** as first-class alertable signals.
- [ ] **Exemplars** + `trace_id`-correlated logs for click-through.

## Minimal first cut

If starting small, instrument in this order:
1. RED metrics + traces on **web** (auto via Rack/Sinatra instrumentation).
2. **traceparent** propagation web → RabbitMQ → Sidekiq.
3. Sidekiq + Bunny auto-instrumentation (job/consume spans + queue metrics).
4. A handful of **business counters** (orders placed/paid, events by type).
5. `trace_id` in logs + exemplars.

Expand to event-store internals (conflict rate, projection lag) and saturation
metrics once the backbone is proven.
