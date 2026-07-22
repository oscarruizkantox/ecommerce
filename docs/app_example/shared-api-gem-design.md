# Shared API Gem — Design Guide

How to share the **common HTTP contract** across many services without leaking
any single service's code or config into the shared gem. The gem defines the
*shape* (how to respond); each service provides the *content* (its own
controllers).

Fits the topology in [infrastructure.md](./infrastructure.md) and reuses the
propagation model from
[message-metadata-contract.md](./message-metadata-contract.md).

## When to extract (do this last, not first)

**Until there are two or more services that actually need the shared logic,
everything lives inside the same repository / app / service.** Do not extract a
gem (or the contract, or the monorepo) on day one for a single service — that is
premature abstraction.

**Extraction is never mandatory — not even at 3 or 4 services.** Having several
consumers only *makes it possible* to extract; it does not force it. If the team
prefers to keep the shared code in-app (or lightly duplicated) because the cost of
a shared library — versioning, releases, coordination, ownership — isn't worth it
yet, that is a legitimate choice. Extract only when the shared surface is both
**proven by real consumers** and **worth the coordination overhead**. Extracting
later from working services is cheap and better-informed; guessing the shared
surface up front is not.

This whole guide describes the **target shape if and when extraction is chosen** —
not a starting point and not an obligation.

## Principle: dependency inversion

```
service  ──depends on──▶  shared gem
shared gem ──never──────▶  any service
```

The gem must never `require`, name, or configure anything that belongs to a
specific service. If you find a service name or business concept inside the gem,
something leaked.

## Composition, not inheritance of app code

The gem offers **pieces you plug into your own controllers** — a formatter, a
mixin module, middleware — **not** base controllers with application logic. The
service owns its controllers and merely *uses* the gem's verbs and formats.

## What goes in the gem (only what is common)

Test for inclusion: *"Is this identical in **every** service and free of any
domain concept?"* If yes → gem. If no → service.

### 1. Response format — a pure object, knows nothing about apps

```ruby
module Flow
  module Api
    class Response
      def self.success(data, status: 200, meta: {})
        [status, JSON.generate({ data: data, meta: meta })]
      end

      def self.error(code:, message:, status:, details: [])
        [status, JSON.generate({ error: { code:, message:, details: } })]
      end
    end
  end
end
```

### 2. A mixin the service includes in its controller (not a base class)

```ruby
module Flow
  module Api
    module Respondable
      def respond(data, status: 200, meta: {})
        status, body = Response.success(data, status:, meta:)
        halt status, { "Content-Type" => "application/json" }, body
      end

      def respond_error(error)
        code, message, status = ErrorMap.for(error)
        _, body = Response.error(code:, message:, status:)
        halt status, { "Content-Type" => "application/json" }, body
      end
    end
  end
end
```

### 3. The common error → HTTP mapping

Shared contract: validation → 422, not-found → 404, unauthorized → 401, etc. The
gem maps *error categories*, never specific domain errors — a service registers
its own errors against the shared categories.

### 4. Cross-cutting middleware (config injected by the app)

JWT verification, request metadata, security headers, CORS — mountable in
plain-Ruby Rack, Sinatra, and Rails alike. **Config comes from the app at mount
time**, never from inside the gem:

```ruby
use Flow::Api::JwtMiddleware, public_key: ENV.fetch("JWT_PUBLIC_KEY")
```

## What stays in each service

Its own controllers, which only *use* the gem's pieces:

```ruby
class OrdersController < Sinatra::Base
  include Flow::Api::Respondable            # from the gem

  post "/" do
    result = COMMAND_BUS.(PlaceOrder.new(params))   # the service's logic
    respond({ id: result.id }, status: 201)          # the gem's format
  rescue Domain::ValidationError => e
    respond_error(e)                                 # the gem's mapping
  end
end
```

Routing, endpoints, commands, aggregates, read models, persistence and schema —
all owned by the service. The gem never references any of them.

## Rules that keep the gem clean

1. **Strict dependency direction** — `app → gem`, never the reverse.
2. **The gem reads no ENV / no own config** — everything is passed as arguments at
   construction/mount. Config belongs to the app.
3. **Modules and plain objects, not base classes carrying app behavior.** If
   inheritance is unavoidable, the base must be free of any business logic.
4. **Framework-neutral (Rack/Sinatra)** so it works in both plain-Ruby and Rails
   services, and survives a later migration to Rails (routing/controllers change;
   auth, formats, errors, metadata already live in the gem).
5. **It is a contract — version it with semver.** Changing the response format is a
   breaking change for every consumer; treat the gem as a platform product with an
   owner, CI, and a rollout strategy.

## Gateway + JWT placement

- **Gateway/edge**: authenticates the JWT, terminates TLS, rate-limits, routes.
- **Service**: trusts (or re-verifies the signature of) the JWT and does
  fine-grained authorization. Claim extraction + verification live in the gem's
  middleware; the authorization *decision* is the service's.
- Propagate user/tenant/correlation inward via headers → ties into the metadata
  contract and the `traceparent` used by OpenTelemetry.

## In one line

**The gem defines the form (contract); the service provides the content
(controllers).** The gem offers verbs (`respond`, `respond_error`) and formats;
each app writes its own sentences.
