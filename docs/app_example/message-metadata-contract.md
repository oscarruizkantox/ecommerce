# Message & Event Metadata Contract

One metadata contract shared across every boundary a message crosses: RabbitMQ
transport, the RubyEventStore event log, and OpenTelemetry trace context. The
goal is that a single external request is traceable and correlatable end to end,
and that no service has to guess which fields are present.

## Why this exists (current state)

Two reference apps, two different gaps:

- **rate-alerts** (Puma + Sneakers + RabbitMQ, no event store): correlation id
  (`SecureRandom.uuid`) is buried inside the JSON *payload*; the `id_key` passed
  to `publish` is used only for error logging and never becomes an AMQP property.
  `GENERIC_METADATA` is empty (`{}` with a `TODO: inject APP + ECS SERVICE`). No
  `message_id`, `correlation_id`, `traceparent`, or `delivery_mode`.
- **ecommerce** (RubyEventStore): event `metadata:` is used only for business
  facts — RES auto-stamps `:timestamp`, and pricing sets `:valid_at`. There is
  **no** `correlation_id` / `causation_id` / `request_id`, though RES supports
  them as first-class metadata.

Neither app can currently stitch a trace across a service hop.

## The three layers

A message carries three *separate* concerns. Keep them separate:

| Layer | Where it lives (AMQP) | Where it lives (RES) | Purpose |
|---|---|---|---|
| **Identity & correlation** | AMQP basic properties | event `metadata` | who/what/when, causal chain |
| **Context propagation** | AMQP `headers` | event `metadata` | trace context, tenancy |
| **Business payload** | message body (JSON) | event `data` | domain facts only |

The bug in both apps is mixing these — instance info and correlation ids ending
up in the business payload.

## Canonical fields

These are the contract. Every producer sets them; every consumer may assume them.

### Identity & correlation

| Field | Meaning | AMQP property | RES metadata key |
|---|---|---|---|
| `message_id` | Unique per physical message | `message_id` | — (per-event `event_id`) |
| `correlation_id` | Stable id for the whole causal chain / originating request | `correlation_id` | `:correlation_id` |
| `causation_id` | The id of the direct cause (message/command/event) | header `causation_id` | `:causation_id` |
| `request_id` | The originating HTTP request, if any | header `request_id` | `:request_id` |
| `type` | Message/event name (e.g. `pricing.price_set`) | `type` | (event class) |
| `timestamp` | Emit time | `timestamp` | `:timestamp` (RES auto) |
| `app_id` | Emitting service + revision | `app_id` | `:source` |

### Context propagation (headers / metadata)

| Field | Meaning |
|---|---|
| `traceparent` | W3C trace context (OTel) — the span this message continues |
| `tracestate` | W3C vendor trace state |
| `tenant` / `session_id` | Tenancy / session correlation where relevant |
| `source` | Emitting service name (`rate-alerts`, `ordering`, …) |
| `revision` / `hostname` | From the app metadata object, for debugging |

### Business payload

Pure domain data. Currency pair, tenor, order id, price — nothing infra.

## Propagation rules

The chain that keeps a trace and a correlation id alive across hops:

```
inbound HTTP request
  request_id      = <from web layer / generated>
  correlation_id  = request_id                     (start of the chain)
  traceparent     = <OTel current span>

→ command dispatched
  causation_id    = <the request>

→ event(s) published (RES)
  metadata: { correlation_id, causation_id: <command/prior event>,
              request_id, source, traceparent }
  (RES adds :timestamp; correlation_id/causation_id propagate to child events)

→ outbound RabbitMQ publish
  properties: { message_id: new uuid, correlation_id, type, timestamp, app_id }
  headers:    { traceparent, causation_id: <the event>, request_id, source }

→ consumer receives (Sneakers #work)
  extract traceparent  → continue the trace
  read correlation_id  → same chain
  causation_id of next = this message_id
```

**Rule of thumb**: `message_id`/`event_id` is always new; `correlation_id` is
copied unchanged down the whole chain; `causation_id` is set to the id of the
thing that directly caused this one.

## RubyEventStore mapping

RES already supports this — it is just unused. Set correlation/causation on the
metadata inside a `with_metadata` block, keyed off the incoming command/message:

```ruby
event_store.with_metadata(
  correlation_id: context.correlation_id,
  causation_id:   context.causation_id,
  request_id:     context.request_id,
  source:         "ordering"
) do
  repository.with_aggregate(Order, cmd.order_id) { |o| o.place }
end
```

Child events published while the block is open inherit these. Read models and
process managers then read `event.metadata.fetch(:correlation_id)` the same way
they already read `event.metadata.fetch(:timestamp)`.

> This composes with the existing pricing usage
> (`@event_store.with_metadata(valid_at: cmd.valid_since)`) — business metadata
> and correlation metadata live in the same hash; just merge them.

## RabbitMQ mapping

Replace the empty `GENERIC_METADATA` with an envelope builder, and stop using
`id_key` for anything but logs. Both `RabbitMqServices` stacks already funnel
through `routing_params.merge(metadata).merge(headers: headers)`, so this is a
single seam:

```ruby
def envelope(type:, correlation_id:, causation_id:, context:)
  properties = {
    message_id:    SecureRandom.uuid,
    correlation_id: correlation_id,
    type:          type,
    timestamp:     Time.now.to_i,
    content_type:  "application/json",
    app_id:        "#{APP_METADATA['source']}@#{APP_METADATA['revision']}",
    delivery_mode: 2
  }
  headers = {
    "causation_id" => causation_id,
    "request_id"   => context.request_id,
    "source"       => APP_METADATA["source"]
  }
  OpenTelemetry.propagation.inject(headers)   # adds traceparent/tracestate
  [properties, headers]
end
```

Consumers get a small extractor that rebuilds the context and continues the
trace:

```ruby
def self.extract(properties, headers)
  OpenTelemetry.propagation.extract(headers)  # continue the trace
  Context.new(
    correlation_id: properties[:correlation_id],
    causation_id:   properties[:message_id],   # this message causes the next
    request_id:     headers["request_id"]
  )
end
```

## OpenTelemetry mapping

- `traceparent`/`tracestate` are the OTel W3C context — injected into headers on
  publish, extracted in every consumer `#work` and every inbound HTTP request.
- `correlation_id`, `request_id`, `tenant` become **span attributes** so traces
  are filterable in Grafana/Tempo by business identity.
- `app_id` / `source` feed the `service.name` resource attribute.

This is the single seam where transport, event log, and tracing all meet: define
the envelope once and all three signals stay consistent.

## Implementation checklist

- [ ] **ecommerce**: a `Context` value object (correlation/causation/request id)
      threaded from the command bus into `event_store.with_metadata`.
- [ ] **ecommerce**: web/command entrypoints seed `correlation_id = request_id`.
- [ ] **rate-alerts**: replace `GENERIC_METADATA` with the envelope builder;
      retire `id_key` (→ `message_id`); set `delivery_mode: 2` on durable flows.
- [ ] **rate-alerts**: `Envelope.extract` in every `Sneakers::Worker#work`.
- [ ] **both**: OTel inject on publish / HTTP out, extract on consume / HTTP in.
- [ ] **both**: business payloads carry domain data only — no instance/correlation
      fields in the body.
