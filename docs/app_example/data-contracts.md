# Data Contracts — Community Standards & Conventions

Before defining our own API-object shapes and event schemas, use what the
community already standardized. This document catalogs the established
specifications and conventions, and which to adopt. It complements
[cross-language-contract.md](./cross-language-contract.md) (how contracts stay
identical across Ruby/Elixir/Java) and
[shared-api-gem-design.md](./shared-api-gem-design.md) (how the response format is
shared).

## Principle: Convention over Configuration (CoC)

Popularized by Rails (DHH), CoC means: **agree sensible defaults once, and only
specify the exceptions.** Applied to data contracts, you don't re-decide field
naming, timestamps, or error shape per service — you adopt a convention and every
service follows it. Less configuration, fewer decisions, uniform output. This is
the cheapest, highest-leverage move: a **conventions document** costs nothing and
makes services consistent from day one, long before any formal schema exists.

## API representation standards

| Standard | What it is | Use for |
|---|---|---|
| **OpenAPI** (fka Swagger) | REST API description language | describing HTTP endpoints + payloads; codegen, docs, mocks |
| **JSON Schema** | validation vocabulary for JSON | the schema underneath OpenAPI; validating request/response bodies |
| **JSON:API** (jsonapi.org) | strong convention for resources | resource shape (`data`/`attributes`/`relationships`/`links`/`meta`), pagination, sparse fieldsets, errors — CoC in a box |
| **RFC 9457** (obsoletes **RFC 7807**) | Problem Details, `application/problem+json` | the **standard error format** — don't invent your own |
| **HAL** / **JSON-LD + Hydra** | hypermedia link formats | if you want HATEOAS/linked data |
| **GraphQL** | typed schema + query language | an alternative to REST when clients need flexible querying |

### The two candidates for our resource shape

We narrowed the resource representation to two options, using the same `Order`
(id, status, total 42.00 EUR, created_at, a customer relationship).

**Option A — house envelope** (flat, minimal): the object goes straight in `data`,
with `meta` for cross-cutting fields.

```json
{
  "data": {
    "id": "ord_9f2a",
    "status": "paid",
    "total": { "amount_minor": 4200, "currency": "EUR" },
    "created_at": "2026-07-22T10:00:00Z",
    "customer_id": "cus_1a2b"
  },
  "meta": { "request_id": "req_77" }
}
```

**Option B — JSON:API (ADOPTED)**: a complete convention — separates
`type`/`id`/`attributes`/`relationships`/`links`, standardizes how related
resources are referenced and navigated, plus ready-made rules for pagination,
sparse fieldsets, and errors.

```json
{
  "data": {
    "type": "orders",
    "id": "ord_9f2a",
    "attributes": {
      "status": "paid",
      "total": { "amount_minor": 4200, "currency": "EUR" },
      "created_at": "2026-07-22T10:00:00Z"
    },
    "relationships": {
      "customer": { "data": { "type": "customers", "id": "cus_1a2b" } }
    },
    "links": { "self": "/orders/ord_9f2a" }
  }
}
```

> **DECISION (adopted): JSON:API.** It is Convention over Configuration in a
> box — relationships, pagination, sparse fieldsets, and error shape are already
> specified, so services don't re-invent them and clients/tooling understand the
> format out of the box. The cost is more verbosity than the house envelope; the
> gain is a shared, documented convention across every service and language.
> The flat house envelope is a fallback only for a service that needs maximally
> lightweight payloads and doesn't benefit from JSON:API's relationship/navigation
> machinery.

## Event & messaging standards

| Standard | What it is | Use for |
|---|---|---|
| **CloudEvents** (CNCF) | vendor-neutral **event envelope** (`id`, `source`, `type`, `specversion`, `time`, `subject`, `data`) | the **adopted** event envelope — the standard wrapper for events across services/languages; see [message-metadata-contract.md](./message-metadata-contract.md) |
| **AsyncAPI** | description language for event-driven APIs (channels, messages) | "OpenAPI for messaging" — documents RabbitMQ channels/messages |
| **Protobuf** (protobuf.dev) | IDL + binary serialization | cross-language event payloads with codegen (Ruby/Elixir/Java); already used in rate-alerts |
| **Apache Avro** | schema + row serialization | streaming pipelines; strong schema evolution |
| **Schema Registry** (Confluent) | central schema store + **compatibility modes** (BACKWARD / FORWARD / FULL) | enforcing that event schemas only evolve compatibly |

## Data contract standards (data engineering / lakehouse)

The "data contract" movement formalizes the agreement between a data **producer**
and **consumer** — schema + semantics + quality/SLA + versioning:

| Standard | What it is |
|---|---|
| **Data Contract Specification** (datacontract.com) | open YAML spec for dataset contracts (schema, quality, SLA, terms) |
| **Open Data Contract Standard (ODCS)** | standard under the Linux Foundation's Bitol project (donated by PayPal) |
| **dbt model contracts** | enforce column names/types on dbt models |
| **Table formats**: Apache Iceberg, Delta Lake, Parquet, Avro | the physical schema of data at rest (see [data-archival.md](./data-archival.md)) |

These are what govern events flowing into the lakehouse: the event schema **is**
the data contract, versioned with compatibility rules.

## Cross-cutting field conventions (adopt these)

Community-standard building blocks — no need to invent:

- **Timestamps**: **ISO 8601 / RFC 3339**, UTC (`2026-07-22T10:00:00Z`).
- **Money**: **ISO 4217** currency code + integer **minor units**
  (`{ "amount_minor": 4200, "currency": "EUR" }`) or decimal string — **never
  floats**. Critical for FX.
- **IDs**: **UUID (RFC 4122)**, or **ULID** (sortable), optionally type-prefixed
  Stripe-style (`ord_…`, `alr_…`).
- **Enums**: closed, documented strings — never magic integers.
- **Field naming**: pick one (`snake_case` is the common JSON-API convention) and
  never mix.
- **Versioning**: **Semantic Versioning** (semver.org) for contracts and gems;
  additive changes are minor, breaking changes are a new major / new event version.
- **Nullability**: explicit; distinguish "absent" from `null`.

## What to adopt here (recommendation)

Compose established standards rather than a bespoke house style:

- **HTTP responses** → **JSON:API** (adopted; see the two candidates above),
  validated with **JSON Schema**, errors as **RFC 9457 problem+json**. The flat
  house envelope is the fallback for services that need lightweight payloads.
- **API description** → **OpenAPI**.
- **Event envelope** → **CloudEvents** shape, carried in the RabbitMQ/RES metadata
  (aligns with [message-metadata-contract.md](./message-metadata-contract.md)).
- **Event payloads (cross-language / lakehouse)** → **Protobuf** (codegen for
  Ruby/Elixir/Java) or Avro, versioned with **BACKWARD** compatibility.
- **Async description** → **AsyncAPI**.
- **Lakehouse data contracts** → **Data Contract Specification** or **ODCS**, with
  the event schema as source of truth.
- **Field conventions** → the list above.

## Principle (consistent with the rest of this section)

**Conventions now, formal schemas when a real consumer needs them.** Write the
conventions document from day one (free, immediate consistency). Formalize
machine-readable schemas — OpenAPI/JSON Schema for APIs, Protobuf/CloudEvents for
events, a Data Contract for the lakehouse — only when a **second implementation**
(Ruby ↔ Elixir) or the **lakehouse** actually consumes them. Don't build a schema
registry for a single service.
