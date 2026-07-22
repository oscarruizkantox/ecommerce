# Running RubyEventStore without Rails (Postgres storage)

RubyEventStore is framework-agnostic. `RailsEventStore` is only a thin layer
(ActiveRecord glue + `after_commit` dispatching) on top of `ruby_event_store`.
This project already drives the domains outside Rails — see any
`domains/<name>/test/` suite, which runs on `Infra::EventStore.in_memory`
(a bare `RubyEventStore::Client` with an `InMemoryRepository`).

This document shows how to run the same setup but **persisting to Postgres**,
still with **no Rails booted**.

## What you need

The persistence layer lives in `ruby_event_store-active_record`, which ships a
pure-ActiveRecord repository (`RubyEventStore::ActiveRecord::EventRepository`).
It needs a live ActiveRecord connection — nothing else from Rails.

Gems (versions from `apps/rails_application/Gemfile.lock`; the `sidekiq` ones
are **not yet in any bundle** and must be added):

- `activerecord` (8.0.3) — present
- `pg` (1.6.2) — present
- `ruby_event_store` (2.17.1) — present
- `ruby_event_store-active_record` (2.17.1) — present
- `sidekiq` (~> 8.0, latest) — **add** (event executor: runs async event handlers)
- `ruby_event_store-sidekiq` — **add** (provides `RubyEventStore::Sidekiq::Scheduler`)
- `kicks` — **add** (inbound consumer: reads RabbitMQ, enqueues a Sidekiq job; maintained Sneakers fork)

Runtime: **Ruby 3.4** (the project's current, `3.4.7`), which Sidekiq 8
supports. Sidekiq 8 requires **Redis 7.2+**; the Docker `redis` service
(`redis:7-alpine`) satisfies this and injects `REDIS_URL`
(`redis://redis:6379/0`) into the app services.

## 1. Schema

The repository expects two tables: `event_store_events` and
`event_store_events_in_streams`. Create them with the generator that ships in
the gem (no Rails needed):

```ruby
require "ruby_event_store/active_record"

RubyEventStore::ActiveRecord::MigrationGenerator.new.call(
  "postgresql",      # data_type for the payload columns
  "db/migrate"       # output directory
)
```

Then run that migration against your database, or apply the equivalent SQL. In
this repo the tables are already created by the Rails app's migrations, so a
standalone script can point at the same `DATABASE_URL` and reuse them.

## 2. Building the client (Postgres storage + Sidekiq worker)

Use a single YAML serializer for **both** persistence and Sidekiq scheduling —
the async worker must deserialize with the same serializer that scheduled the
job.

```ruby
require "active_record"
require "sidekiq"
require "ruby_event_store"
require "ruby_event_store/active_record"
require "ruby_event_store/sidekiq"

ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
Sidekiq.configure_client { |c| c.redis = { url: ENV.fetch("REDIS_URL") } }

SERIALIZER = RubyEventStore::Serializers::YAML

client = RubyEventStore::Client.new(
  repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: SERIALIZER),
  dispatcher: RubyEventStore::ComposedDispatcher.new(
    RubyEventStore::ImmediateAsyncDispatcher.new(
      scheduler: RubyEventStore::Sidekiq::Scheduler.new(serializer: SERIALIZER)
    ),
    RubyEventStore::ImmediateDispatcher.new
  )
)
```

- `ComposedDispatcher` tries each dispatcher in order. Async (Sidekiq) handlers
  are matched first and enqueued; everything else falls through to the
  synchronous `ImmediateDispatcher`.
- `RubyEventStore::Serializers::YAML` is the default RES serializer and the
  recommended choice — it round-trips Ruby objects in event payloads without the
  type-preservation pipeline the JSON path needs.

## 3. Subscribing handlers

A **synchronous** handler is any object responding to `#call(event)`:

```ruby
class SyncHandler
  def call(event)
    # runs inline, in the publishing process
  end
end
client.subscribe(SyncHandler.new, to: [SomeEvent])
```

An **asynchronous** handler is a Sidekiq worker. It is enqueued on publish and
runs in the Sidekiq process; deserialize the event with the same serializer:

```ruby
class AsyncHandler
  include Sidekiq::Job

  def perform(payload)
    event = SERIALIZER.load(payload)
    # ... runs in the Sidekiq worker process
  end
end
client.subscribe_to_all_events(AsyncHandler)
```

### With Sidekiq Enterprise

Enterprise (already licensed here) adds features worth using for event-driven
work — enable them per handler, no change to the dispatcher wiring:

- **Reliable fetch** (`super_fetch`) — an async handler that crashes mid-run is
  requeued instead of lost, so a published event's side effect isn't dropped.
  Enable in the worker config, not in code (see the Docker section).
- **Unique jobs** — dedupe handlers for the same event (e.g. at-least-once
  redelivery, retries): `sidekiq_options unique_for: 1.hour`.
- **Rate limiting** — throttle handlers that call external services so a burst
  of events can't overwhelm them (`Sidekiq::Limiter.bucket(...)`).
- **Batches** — group the async handlers fired by a replay/rebuild and run a
  callback when they all finish.

```ruby
class AsyncHandler
  include Sidekiq::Job
  sidekiq_options unique_for: 1.hour, queue: "events"

  LIMITER = Sidekiq::Limiter.bucket("handler", 100, :minute)

  def perform(payload)
    event = SERIALIZER.load(payload)
    LIMITER.within_limit { handle(event) }
  end
end
```

### Inbound consumer: Sneakers / Kicks (RabbitMQ)

Sidekiq and Kicks play **different roles** — they are not interchangeable async
backends:

- **Kicks is the inbound consumer** (ingress). It reads messages off RabbitMQ and
  does one thing: enqueue a Sidekiq job carrying the received message. It is
  *not* an RES scheduler and it does not touch the event store directly — it just
  hands off.
- **Sidekiq starts the event store flow.** The job deserializes the message,
  runs the command / publishes the event into `EVENT_STORE`, and from there RES
  persists to Postgres and schedules any further async subscribers (also Sidekiq).

Use **`kicks`** — the maintained fork of Sneakers (`gem "kicks"`, still
`require "sneakers"`). The consumer is a thin `Sneakers::Worker`:

```ruby
require "sneakers"

class InboundConsumer
  include Sneakers::Worker
  from_queue "inbound"

  def work(payload)
    ProcessInboundMessage.perform_async(payload)   # hand off to Sidekiq
    ack!
  end
end
```

The Sidekiq job is where the event store flow begins:

```ruby
class ProcessInboundMessage
  include Sidekiq::Job

  def perform(payload)
    message = SERIALIZER.load(payload)
    EVENT_STORE.publish(
      SomeEvent.new(data: message),
      stream_name: "Something$#{message.fetch(:id)}"
    )
  end
end
```

The full flow:

```
RabbitMQ --> Kicks consumer --> enqueue Sidekiq job (raw message)
         --> Sidekiq job: EVENT_STORE.publish
         --> RES persists to Postgres + schedules async subscribers
         --> Sidekiq runs those subscribers
```

Two processes share the same boot file (event classes, serializer,
subscriptions): the consumer (`bundle exec sneakers work InboundConsumer`) and
Sidekiq (`bundle exec sidekiq`). The dispatcher wiring in step 2 is unchanged —
Sidekiq is both the entry point (via `ProcessInboundMessage`) and the executor
of the async event subscribers.

## 4. Publishing and reading

```ruby
class OrderPlaced < RubyEventStore::Event
end

stream = "Order$demo-1"

client.publish(OrderPlaced.new(data: { order_id: "demo-1", total: 42 }), stream_name: stream)

client.read.stream(stream).each do |event|
  puts "#{event.event_type} #{event.data.inspect}"
end
```

`defined?(Rails)` is `nil` throughout — events are persisted in Postgres via
ActiveRecord, and async handlers run under Sidekiq, all without Rails.

## Streams — naming and examples

A stream is just a named, ordered sequence of events. RES stores each event once
in `event_store_events` and records its membership in one or more streams via
`event_store_events_in_streams`. You choose the names; the convention in this
project (see the domain tests) is `Aggregate::Name$#{id}`.

**Per-aggregate stream** — the source of truth for one entity. Use
`expected_version` for optimistic concurrency:

```ruby
order_id = "b8f1..."
stream   = "Ordering::Order$#{order_id}"

client.publish(OrderPlaced.new(data: { order_id: order_id, total: 42 }),
               stream_name: stream, expected_version: -1)   # -1 = stream must be empty
client.publish(OrderPaid.new(data: { order_id: order_id }),
               stream_name: stream, expected_version: 0)    # next event after the first
```

**Category / projection streams via linking** — keep the event in its aggregate
stream, then *link* it into wider streams for read models. Linking never copies
the event, it adds a membership row:

```ruby
event = client.publish(OrderPlaced.new(data: { order_id: order_id }),
                       stream_name: "Ordering::Order$#{order_id}")

client.link(event.event_id, stream_name: "Ordering::Order")        # all orders (category)
client.link(event.event_id, stream_name: "orders-2026-07")         # by month, for reporting
client.link(event.event_id, stream_name: "customer-#{cust_id}")    # everything for a customer
```

(This is what `Infra::EventStore#link_event_to_stream` wraps.)

**Reading streams**

```ruby
client.read.stream("Ordering::Order$#{order_id}").to_a   # one aggregate, oldest→newest
client.read.stream("Ordering::Order").last(50).to_a      # 50 most recent across all orders
client.read.stream("Ordering::Order$#{order_id}").backward.first   # latest event only
```

**Global stream** — every event, in append order, no stream name needed. Useful
for a catch-all subscriber or a full rebuild:

```ruby
client.read.to_a                        # all events ever
client.subscribe_to_all_events(AsyncHandler)   # already used above
```

## Wiring it into `Infra::EventStore`

To make this a first-class option alongside `.in_memory` and `.main`, add a
factory to `infra/lib/infra/event_store.rb`:

```ruby
def self.postgres(serializer: RubyEventStore::Serializers::YAML)
  new(
    RubyEventStore::Client.new(
      repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: serializer),
      dispatcher: RubyEventStore::ComposedDispatcher.new(
        RubyEventStore::ImmediateAsyncDispatcher.new(
          scheduler: RubyEventStore::Sidekiq::Scheduler.new(serializer: serializer)
        ),
        RubyEventStore::ImmediateDispatcher.new
      )
    )
  )
end
```

The caller is responsible for having established the ActiveRecord connection
(`ActiveRecord::Base.establish_connection(...)`) and configured the Sidekiq
client (`Sidekiq.configure_client { |c| c.redis = ... }`) first.

> Note: `infra.gemspec` currently depends only on `ruby_event_store`. Using this
> factory requires adding `ruby_event_store-active_record`, `ruby_event_store-sidekiq`,
> `activerecord`, `pg`, and `sidekiq` to the `infra` gem's dependencies.

## Running in Docker

Everything runs in Docker in this project. The `postgres` service and the Rails
app bundle already provide the required gems and a migrated schema:

```sh
docker compose up -d postgres redis rabbitmq
docker compose run --rm web bundle exec sneakers work InboundConsumer -r ./config/boot.rb   # RabbitMQ consumer
docker compose run --rm web bundle exec sidekiq -r ./config/boot.rb                          # background jobs + event executor
```

> Note: RabbitMQ is not yet a service in `docker-compose.yml` — running the Kicks
> consumer requires adding one (e.g. `rabbitmq:3-management`) and a
> `RABBITMQ_URL` env var alongside the existing `postgres` and `redis` services.

With **Sidekiq Enterprise**, turn on reliable fetch in the worker config so
in-flight event handlers survive a crash (`config/sidekiq.rb`):

```ruby
Sidekiq.configure_server do |config|
  config.super_fetch!          # Enterprise: requeue orphaned jobs on crash
  config.redis = { url: ENV.fetch("REDIS_URL") }
end
```

`DATABASE_URL` and `REDIS_URL` are injected by the `web` service
(`postgres://postgres:secret@postgres/cqrs-es-sample-with-res_development`,
`redis://redis:6379/0`). The Sidekiq process must `require` the same file so the
event classes and worker handlers are defined and subscribed.

## Web server (Rack, no Rails)

The HTTP side follows the same no-Rails approach — **Puma serving a Rack app**,
with Sinatra controllers mounted via `Rack::Builder`. This mirrors the
`rate-alerts` app (`~/workspace/oscarruizkantox/rate-alerts`), which runs exactly
this stack (Puma + Rack + Sinatra + `kicks`, no Rails).

**Gemfile additions**

```ruby
gem "puma", "~> 6.0"
gem "sinatra", "~> 4.2", require: false
gem "rack"
```

**config.ru** — the Rack entry point:

```ruby
$LOAD_PATH << File.expand_path(__dir__)

require_relative "config/boot"   # event store, connections, serializer
require_relative "app"           # the Rack app (controllers)

run Myapp.rack_app
```

**app.rb** — mount controllers with `Rack::Builder`:

```ruby
module Myapp
  def self.rack_app
    @rack_app ||= Rack::Builder.new do
      map("/orders")    { run OrdersController }
      map("/heartbeat") { run HeartbeatController }
      map("/")          { run DashboardController }
    end
  end
end
```

**A controller** — a Sinatra app that drives the event store via a command bus,
then the browser/API reads from a projection (never rebuilds from events inline):

```ruby
class OrdersController < Sinatra::Base
  post "/" do
    COMMAND_BUS.(PlaceOrder.new(order_id: params.fetch("id")))
    status 201
  end

  get "/:id" do
    order = ReadModel::Orders.find(params.fetch("id"))   # from a projection, not events
    json order
  end
end
```

**config/puma.rb** — same shape as `rate-alerts`; disconnect pooled resources
before fork so each worker reconnects cleanly:

```ruby
workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
threads 1, ENV.fetch("MAX_THREADS", 5).to_i
preload_app!
port ENV.fetch("PORT", 3000)

before_fork do
  defined?(ActiveRecord::Base) && ActiveRecord::Base.connection_pool.disconnect!
end
```

Run it: `bundle exec puma -C config/puma.rb config.ru`.

This gives three process types, all sharing `config/boot.rb` and none loading
Rails:

- **web** (Puma) — accepts requests, dispatches commands, reads projections.
- **consumer** (Kicks) — RabbitMQ ingress → enqueues Sidekiq jobs.
- **worker** (Sidekiq) — runs the event store flow and async subscribers.

## Data retention — pruning events/streams older than a year

> **Caveat first.** An event store is append-only by design: events are the
> source of truth and replaying them rebuilds every read model. RubyEventStore
> deliberately offers **no public API to delete events** — only
> `client.delete_stream(name)`, which removes the *stream links* (the rows in
> `event_store_events_in_streams`) but keeps the events themselves in
> `event_store_events`. Physically deleting events breaks auditability and any
> future rebuild that relies on them. Treat the following as a **workaround**,
> only for streams whose lifecycle is genuinely finished and whose events no
> read model will ever need to replay.

There is no built-in TTL. You prune with a scheduled job that deletes rows
directly through the gem's ActiveRecord models. "Completed" is a
domain concept RES doesn't track, so you decide it — e.g. a stream is complete
once it has emitted a terminal event (`OrderCompleted`, `ReturnClosed`, …).

```ruby
require "active_record"
require "ruby_event_store/active_record"

class PruneOldEvents
  include Sidekiq::Job

  Event         = RubyEventStore::ActiveRecord::Event
  EventInStream = RubyEventStore::ActiveRecord::EventInStream

  def perform(cutoff_iso = nil)
    cutoff = cutoff_iso ? Time.iso8601(cutoff_iso) : (Time.now.utc - 365 * 24 * 60 * 60)

    ActiveRecord::Base.transaction do
      old_event_ids = Event.where("created_at < ?", cutoff).select(:event_id)

      EventInStream.where(event_id: old_event_ids).delete_all
      Event.where(event_id: old_event_ids).delete_all
    end
  end
end
```

Scope it to *completed* streams so you never prune events belonging to a still-
open aggregate. One approach — collect the stream names you consider complete,
then delete only within those:

```ruby
completed_streams = ReadModel::CompletedOrders.stream_names   # your projection

links = EventInStream
  .where(stream: completed_streams)
  .where("created_at < ?", cutoff)

event_ids = links.select(:event_id)

ActiveRecord::Base.transaction do
  links.delete_all
  # delete the event body only if it is no longer linked from any other stream
  Event.where(event_id: event_ids)
       .where.not(event_id: EventInStream.select(:event_id))
       .delete_all
end
```

Schedule `PruneOldEvents` daily. With **Sidekiq Enterprise** use its built-in
periodic jobs — no `sidekiq-cron` dependency (`config/sidekiq.rb`):

```ruby
Sidekiq.configure_server do |config|
  config.super_fetch!
  config.redis = { url: ENV.fetch("REDIS_URL") }

  config.periodic do |mgr|
    mgr.register("0 3 * * *", "PruneOldEvents")   # daily at 03:00 UTC
  end
end
```

Always run the prune inside a transaction so a partial delete can't leave an
event without its stream links or vice versa. Prune is a good candidate for a
**unique job** (`sidekiq_options unique_for: 1.day`) so overlapping runs can't
double up.
