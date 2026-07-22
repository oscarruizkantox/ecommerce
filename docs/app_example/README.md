# App Example — Non-Rails RubyEventStore

Design docs for running an event-sourced application **without Rails**: a
framework-agnostic `RubyEventStore` core on Postgres, driven by a Rack web
server and RabbitMQ/Sidekiq background processes, deployed on AWS and observed
with OpenTelemetry.

The app is three Rails-free process types sharing one boot file:

- **web** — Puma + Rack + Sinatra: accepts requests, dispatches commands.
- **consumer** — Kicks (RabbitMQ): ingress, hands off to Sidekiq.
- **worker** — Sidekiq: runs the event store flow and async subscribers.

## Documents

1. **[running-res-without-rails.md](./running-res-without-rails.md)** — the core:
   RubyEventStore on Postgres (`ruby_event_store-active_record`), the YAML
   serializer, streams, sync/async handlers, the Kicks → Sidekiq flow, the Rack
   web server, and data retention.
2. **[message-metadata-contract.md](./message-metadata-contract.md)** — the shared
   metadata contract across every boundary: AMQP properties ↔ RES event metadata
   ↔ OpenTelemetry trace context (identity, correlation/causation, propagation).
3. **[infrastructure.md](./infrastructure.md)** — AWS infrastructure and
   guidelines aligned with Kantox Platform/SRE: ECS vs EKS decision,
   component→resource mapping, Terraform layout, naming, state, CI/CD, and
   per-service independent autoscaling.
4. **[observability-otel.md](./observability-otel.md)** — the OpenTelemetry
   design: traces, metrics, and logs across the three processes, end-to-end trace
   propagation, and wiring into the Kantox stack (VictoriaMetrics / Loki /
   Grafana).
5. **[shared-api-gem-design.md](./shared-api-gem-design.md)** — how to share the
   common HTTP contract (response format, error mapping, JWT) across many services
   via a framework-neutral gem, without leaking any service's controllers or
   config into it.

## Suggested reading order

Start with (1) for the application, then (2) since the metadata contract underpins
both correlation and tracing, then (3) for where it runs and (4) for how it's
observed.
