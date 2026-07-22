# Data Archival — Tiering Old Data to Cold Storage

Keep the operational database **small and fast** by moving old, settled data out
of it — **without losing it**. This is *archival* (hot → cold), not deletion:
smaller hot tables mean smaller indexes, cheaper `VACUUM`, better cache hit rates,
and faster reads and writes. It complements the delete-based retention in
[running-res-without-rails.md](./running-res-without-rails.md#data-retention--pruning-eventsstreams-older-than-a-year)
— archive when you must keep the history, prune only when you truly may drop it.

## Principle first

An event store is **append-only and the source of truth**. Archived data must stay
**retrievable, ordered, and immutable** — you are relocating history, not
rewriting it. Never move data you cannot restore or that a live read model still
needs online.

## What is safe to move

Only data that is **settled and no longer needed for online operation**:

- **Completed / closed streams** past a cutoff (e.g. orders finalized > 1 year
  ago) — a stream you consider done because it emitted a terminal event.
- Events **no live read model needs to replay** (projections are already built and
  won't be rebuilt from archived history — or you accept rebuilding from hot only).

Never move events belonging to a **still-open aggregate** or referenced by a
projection you may rebuild online.

## Two techniques (prefer partitioning)

### A. Native Postgres partitioning — detach, don't delete (recommended)

Partition `event_store_events` (and `_in_streams`) **by time** (`created_at`
range, e.g. monthly). Aging out data becomes **detaching a whole partition** — a
metadata operation, not millions of row deletes:

```sql
-- age out: detach the old month, then move it to cold storage
ALTER TABLE event_store_events DETACH PARTITION event_store_events_2024_01;
-- dump + ship the detached table to cold storage, then DROP it from hot
```

This is dramatically cheaper than row-by-row deletion, causes no index bloat, and
needs no `VACUUM FULL`. It requires migrating the RES tables to partitioned tables
up front — plan this before the tables get huge.

### B. Copy-verify-remove batches (works on non-partitioned tables)

When partitioning isn't in place, move in **stream-scoped, resumable batches**:

1. **Select** a batch of settled events (by completed stream + cutoff).
2. **Copy** them to cold storage.
3. **Verify** (row count + checksum) that the copy is intact.
4. **Remove** from hot — inside a transaction, links first then events (see the
   prune SQL in the retention doc for the exact delete order).
5. **Record** the archived range (stream, position range, destination) so it is
   findable later.

Make it **idempotent and resumable** (a crash mid-run must be safe to re-run) and
run it as a scheduled Sidekiq/periodic job during low traffic.

## Where the cold tier lives

| Destination | Best for | Trade-off |
|---|---|---|
| **S3** (JSONL / Parquet batches) | cheapest durable archive; analytics via Athena | not online-queryable by the app without restore |
| **Glacier / S3 tiers** | rarely-accessed compliance retention | slow, high-latency restore |
| **Separate "archive" RDS/Aurora** | occasional online-ish access, same schema | more expensive than object storage |
| **Columnar (Redshift/Athena)** | analytics/reporting over history | not the operational format |

For an event store, **S3 as serialized event batches** (preserving `event_id`,
`stream`, `global_position`, `data`, `metadata`) is the usual default — cheap,
durable, and re-ingestable.

## Preserving order and identity (RES specifics)

- Archive **`event_id`, `stream`, `global_position`/`id`, `data`, `metadata`** so a
  restore reconstructs the exact sequence.
- Detaching/removing old rows leaves **gaps in `global_position`** — that's fine
  (positions are monotonic, not required contiguous), but document it so nobody
  treats a gap as data loss.
- If you archive partial history of a **long-lived** stream, take an **aggregate
  snapshot** first so the aggregate still loads from `snapshot + remaining hot
  events`. If you only archive **fully completed** streams, snapshots aren't
  needed.

## Restoring / reading archived data

Decide and document the access model:

- **Restore on demand**: re-ingest a batch from S3 back into hot (or a temporary
  restore DB) to replay/inspect. Slow but complete.
- **Query in place**: Athena/Glue over the S3 batches for analytics without
  touching the operational DB.
- Make explicit that **archived streams are not online-replayable** by the live
  service until restored — so no read model or command path may depend on them.

## Operational notes

- **Backfill/rebuild policy**: live read models must be rebuildable from **hot data
  only**. If a projection ever needs full history, restore the archive into a
  scratch DB and rebuild there.
- Run archival **off-peak**, throttled, in bounded batches; make it a **unique**
  periodic job so runs can't overlap.
- After large removals on non-partitioned tables, reclaim space
  (`VACUUM`/`pg_repack`); with partitioning this is unnecessary.
- Track metrics: hot table size, rows archived, archive lag, restore time — feed
  them into the observability stack ([observability-otel.md](./observability-otel.md)).

## Applies only once it's worth it

Like the rest of this section, don't build archival up front. Introduce it when the
hot database is actually large enough to hurt performance or cost. If you expect
this from the start, **partition the RES tables by time early** — retrofitting
partitioning onto a huge table is the expensive path.
