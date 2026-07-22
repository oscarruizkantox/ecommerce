# Documentation

Index of everything under `docs/`.

## App example — non-Rails RubyEventStore

Design docs for running an event-sourced app without Rails (RubyEventStore on
Postgres, Rack web + RabbitMQ/Sidekiq processes, AWS, OpenTelemetry). See the
[section README](./app_example/README.md) for the guiding principle and reading
order.

- [app_example/README.md](./app_example/README.md) — overview, guiding principle, reading order
- [app_example/running-res-without-rails.md](./app_example/running-res-without-rails.md) — RES on Postgres, streams, handlers, Kicks → Sidekiq, Rack, retention
- [app_example/message-metadata-contract.md](./app_example/message-metadata-contract.md) — metadata across AMQP ↔ RES ↔ OpenTelemetry
- [app_example/infrastructure.md](./app_example/infrastructure.md) — AWS/Terraform, ECS vs EKS, per-service autoscaling, security
- [app_example/observability-otel.md](./app_example/observability-otel.md) — OpenTelemetry traces/metrics/logs and trace propagation
- [app_example/shared-api-gem-design.md](./app_example/shared-api-gem-design.md) — sharing the common HTTP contract via a framework-neutral gem
- [app_example/cross-language-contract.md](./app_example/cross-language-contract.md) — contract-first, polyglot (Ruby/Elixir/Java), naming (`flow`), conformance
- [app_example/data-contracts.md](./app_example/data-contracts.md) — community standards (OpenAPI, JSON Schema, CloudEvents, Protobuf, ODCS) and field conventions for API objects and events
- [app_example/data-archival.md](./app_example/data-archival.md) — archiving old data to Parquet on S3 (cold storage) to keep the hot DB small and fast; includes the flow diagram

## Architecture diagrams

Mermaid (`.mmd`) diagrams of the ecommerce domain.

- [diagrams/01_high_level_architecture.mmd](./diagrams/01_high_level_architecture.mmd) — high-level architecture
- [diagrams/02_order_lifecycle_flow.mmd](./diagrams/02_order_lifecycle_flow.mmd) — order lifecycle flow
- [diagrams/03_process_managers_orchestration.mmd](./diagrams/03_process_managers_orchestration.mmd) — process managers orchestration
- [diagrams/04_domain_interactions.mmd](./diagrams/04_domain_interactions.mmd) — domain interactions
- [diagrams/05_read_models_event_sources.mmd](./diagrams/05_read_models_event_sources.mmd) — read models and event sources
- [diagrams/06_domain_commands_events.mmd](./diagrams/06_domain_commands_events.mmd) — domain commands and events
- [diagrams/07_payment_and_expiration_flow.mmd](./diagrams/07_payment_and_expiration_flow.mmd) — payment and expiration flow
