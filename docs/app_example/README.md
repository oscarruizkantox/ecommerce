# App Example — Non-Rails RubyEventStore

Design docs for running an event-sourced application **without Rails**: a
framework-agnostic `RubyEventStore` core on Postgres, driven by a Rack web
server and RabbitMQ/Sidekiq background processes, deployed on AWS and observed
with OpenTelemetry.

The app is three Rails-free process types sharing one boot file:

- **web** — Puma + Rack + Sinatra: accepts requests, dispatches commands.
- **consumer** — Kicks (RabbitMQ): ingress, hands off to Sidekiq.
- **worker** — Sidekiq: runs the event store flow and async subscribers.

## Guiding principle: keep it in one place until extraction is justified

**Everything lives inside the same repository / app / service until two or more
services actually need the shared logic.** Extraction (a shared gem, a
language-neutral contract, a monorepo) is **never mandatory — not even at 3 or 4
services**; a count of consumers only makes it *possible*, not required. If the
coordination cost (versioning, releases, ownership) isn't worth it, keeping the
code in-app is a valid choice. Docs 5 and 6 describe the **target shape if and when
extraction is chosen** — not a starting point and not an obligation.

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
6. **[cross-language-contract.md](./cross-language-contract.md)** — the contract
   is not Ruby-only: Ruby and Elixir (and maybe Java) services must respond
   identically. Contract-first, polyglot naming (stem `flow`), the per-ecosystem
   package/module mapping table, and the shared conformance suite that keeps the
   implementations twins.
7. **[data-archival.md](./data-archival.md)** — keep the operational database small
   and fast by tiering old, settled data to cold storage (S3/Glacier) without
   losing it: time partitioning (detach vs delete), copy-verify-remove batches,
   preserving order/identity, and restore/query models.

## Suggested reading order

Start with (1) for the application, then (2) since the metadata contract underpins
both correlation and tracing, then (3) for where it runs and (4) for how it's
observed.
