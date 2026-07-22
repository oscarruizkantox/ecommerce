# Cross-Language Contract & Naming

The shared layers (API response format, auth/JWT, event envelope, telemetry) are
**not Ruby-only** — services exist in **Ruby and Elixir** (and possibly Java
later), and must respond **identically**. A Ruby gem cannot be consumed by Elixir,
so the shared thing cannot be "a gem". The model is **contract-first, polyglot**:
one language-neutral contract as the source of truth, plus twin implementations
per language, kept identical by a shared conformance suite.

## When this applies (not yet)

**Until there are two or more services that require extracting the logic,
everything lives inside the same repository / app / service.** This contract-first,
polyglot structure is the **target** for when a second real consumer (Ruby or
Elixir) exists — not a starting point. With a single service, keep the response
format, envelope, and claims as plain in-app code.

**And even with 3 or 4 services, extraction stays optional.** A count of consumers
makes a shared contract *possible*, never mandatory. If the team decides the
coordination cost isn't worth it, keeping the format in-app (or lightly
duplicated) is a valid choice. Formalize the neutral contract and split into
`contracts/` + per-language libraries only when a twin implementation is actually
wanted and the shared surface has proven stable.

## Model

```
                 ┌──────────────────────────────┐
                 │  CONTRACT (source of truth)   │  language-neutral, no app code
                 │  schemas: response, error,    │
                 │  event envelope, JWT claims   │
                 └───────────────┬──────────────┘
                                 │ generates / validates
        ┌────────────────────────┼────────────────────────┐
        ▼                        ▼                         ▼
  ┌───────────┐          ┌───────────────┐         ┌───────────────┐
  │ Ruby (gem)│  twins → │ Elixir (hex)  │  twins →│ Java (maven)  │
  │ flow-api  │  same    │ flow_api      │  same   │ com.kantox... │
  └───────────┘  output  └───────────────┘ output  └───────────────┘
        └────────────────────────┴────── conformance suite ─────────┘
              (shared golden fixtures: input → expected JSON)
```

The contract is defined **once, in a neutral format**, never in Ruby. Each language
has a library that *implements* it; a shared conformance suite proves the outputs
are byte/semantically identical — twins in fact, not just in name.

## Contract formats (neutral)

| Layer | Neutral contract | Why |
|---|---|---|
| Response / error format | **JSON Schema** (+ OpenAPI for HTTP) | JSON is the lingua franca; every language validates the same schema |
| Event envelope / metadata | **JSON Schema** or **Protobuf** | Protobuf gives codegen for Ruby, Elixir, Java — cannot drift |
| Inter-service event payloads | **Protobuf / Avro** | Versioned contracts with polyglot codegen |
| Async (queues) | **AsyncAPI** | Describes RabbitMQ channels/messages identically for all |
| JWT / claims | **RFC 7519** + claims schema | Standard; each language uses its own JWT lib, same claims |

Source of truth for schemas uses **reverse-DNS, versioned** coordinates — truly
identical across languages, and the basis for codegen:

```proto
package kantox.flow.v1;   // → Flow::V1 (Ruby), Flow.V1 (Elixir), com.kantox.flow.v1 (Java)
```

## Naming — decided: stem = `flow`

**What is fixed and identical across every language:**

- **Product stem (namespace)**: `flow`
- **Capability word**: `api`, `auth`, `eventstore`, `telemetry`
- **Module root (PascalCase)**: `Flow` → reads the same everywhere

**What the ecosystem decides (do not fight it)** — the separator/casing is imposed
by each registry; it is the *idiomatic* form a developer of that language expects,
not a label you add:

| Language | Registry | Package name | Module in code |
|---|---|---|---|
| **Ruby** | RubyGems | `flow-api` (hyphen) | `Flow::Api` |
| **Elixir** | Hex | `flow_api` (underscore) | `Flow.Api` |
| **Java** | Maven | groupId `com.kantox.flow` + artifactId `api` | `com.kantox.flow.api` |
| **npm** (if ever) | npm | `@flow/api` (scoped) | — |

You only ever see `flow-api` and `flow_api` together *inside the monorepo*. In
production a Ruby service sees only gems (`flow-api`), an Elixir service sees only
hex packages (`flow_api`). What everyone perceives, in any language, is **"Flow,
capability api"** — and that is identical.

This is what large polyglot projects do (OpenTelemetry, gRPC, Protobuf, AWS SDK):
one conceptual name, idiomatic packaging per ecosystem. There is no single
cross-registry identifier, and trying to force one fights every package manager.

> **Open consideration (not adopted):** an explicit `flow-api-ruby` /
> `flow-api-elixir` scheme (owner–layer–language) was proposed for extra clarity.
> It is deferred: putting the language in the package name duplicates what the
> registry already implies and diverges from community convention. Revisit only if
> a concrete need appears (e.g. publishing multiple language artifacts to the same
> registry). For now: **stem `flow`, idiomatic separator per ecosystem.**

## Full example

```proto
// contracts/proto/envelope.proto
package kantox.flow.v1;
```

```ruby
# Ruby service
gem "flow-api", "~> 1.3"
include Flow::Api::Respondable
use Flow::Auth::JwtMiddleware, public_key: ENV.fetch("JWT_PUBLIC_KEY")
```

```elixir
# Elixir service — mix.exs
{:flow_api, "~> 1.3"}
# usage
Flow.Api.respond(conn, data, status: 201)
```

Both produce the **same JSON** for the same input — verified by the shared
conformance suite.

## Monorepo layout (polyglot)

```
flow/
├── contracts/            # source of truth (neutral): jsonschema/, openapi/, proto/, asyncapi/
├── conformance/          # shared golden fixtures: input → expected output
├── ruby/                 # flow-api, flow-auth, flow-eventstore, flow-telemetry (gems)
└── elixir/               # flow_api, flow_auth, flow_eventstore, flow_telemetry (hex)
```

Both `ruby/` and `elixir/` run the **same `conformance/`** in CI. If the two
implementations diverge, CI fails.

## In one line

**Fix the stem (`flow`) and the module root (`Flow`); let each ecosystem choose the
separator. The contract — not any one language's code — is the source of truth,
and a shared conformance suite keeps Ruby and Elixir twins.**
