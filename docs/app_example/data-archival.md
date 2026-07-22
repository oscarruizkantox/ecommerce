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

## Interim design (before the lakehouse is ready)

The lakehouse is the eventual home, but it isn't ready and has no date. So pick the
**simplest interim that is already the lakehouse's substrate** — then migrating is
*registering* the data, not moving or reprocessing it.

**Choice: S3 + Parquet, Hive-partitioned, plus a small manifest table.** This is
exactly what a lakehouse (Iceberg/Delta on S3, read by Athena/Spark/Trino/Databricks/
Snowflake) sits on. Nothing here is throwaway.

```
s3://flow-archive/events/event_type=<T>/year=<Y>/month=<M>/part-*.parquet
```

Each file carries full-fidelity columns so any future engine can reconstruct the
history: `event_id`, `stream`, `global_position`, `event_type`, `created_at`,
`data` (JSON string), `metadata` (JSON string).

**The flow now:**
1. Archival job writes settled events to S3 as Parquet (copy).
2. Verify (row count + checksum).
3. **Delete** those rows from the hot DB — these data *are* being removed from the
   operational database (that's the point: smaller, faster hot DB).
4. Record the batch in a **manifest table** (stream, position range, S3 path,
   checksum, archived_at). This small table is the durable source of truth for
   "what was moved and where" — independent of any query engine.

**Querying in the interim (mechanism kept swappable, TBD):** the app only *writes*
and records the manifest; it does **not** bake in a reader. Read the Parquet with
**DuckDB** (`read_parquet('s3://…')` — zero infra, run from a job/laptop) or
**Athena** (serverless SQL) as needed. Because reading is decoupled, you can change
or add engines without touching the archival path.

**Migration to the lakehouse later = near-zero data movement:** the files are
already open Parquet in an open layout. When the lakehouse is ready you either
**register** the existing S3 prefix as an Iceberg/Delta table (a metadata
operation) or do a one-time `CREATE TABLE AS SELECT`. The manifest tells you
exactly what to onboard. No re-export, no format conversion.

**What to avoid for the interim:** a separate archive **RDS/Postgres**. It's tempting
(same tooling) but it's *lock-in* — a database is not the lakehouse substrate, so
later you'd have to export and convert. Choosing S3+Parquet now avoids that second
migration entirely.

> If you want the absolute minimum first step, write **JSONL** instead of Parquet
> (no schema work, trivially re-ingestable) and convert to Parquet before/at
> lakehouse onboarding. Parquet is only slightly more effort now and skips that
> conversion, so prefer it unless you need to ship today.

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

## File format: Apache Parquet (recommended for the S3 tier)

Store archived events as **Apache Parquet** — columnar, compressed, and the native
format of the Apache/AWS analytics stack:

- **Small & cheap**: columnar + compression (Snappy/ZSTD) typically shrinks event
  data several-fold vs JSON → lower S3 cost and faster scans.
- **Directly queryable** (see below) without restoring to a database.
- **Schema-friendly**: keep a stable columnar schema and put the variable parts
  (`data`, `metadata`) as **JSON string columns** (queryable with JSON functions)
  — avoids a per-event-type schema explosion while staying analyzable.

Alternatives: **JSONL** (simplest, best for faithful re-ingest/replay, no schema
work, but bigger and slower to scan); **Avro** (row-oriented, strong schema
evolution — good for streaming pipelines). A common split: **JSONL for
replay-fidelity restore + Parquet for analytics**, or Parquet only if the JSON
columns preserve full fidelity.

### Table format on top: Iceberg / Delta Lake (optional)

For an archive that keeps growing and gets queried, an **open table format**
(**Apache Iceberg** or **Delta Lake**) over the Parquet files adds ACID appends,
**schema evolution**, **time-travel**, and painless compaction. AWS Athena, Glue,
EMR/Spark and Trino all read them. Use it if the archive becomes a real analytics
asset; skip it if it's pure cold retention.

### Layout — partition for cheap scans

Hive-style partitioning so queries prune by time/type and only scan what they need:

```
s3://flow-archive/events/
  event_type=OrderPlaced/year=2024/month=01/part-0001.parquet
  event_type=OrderPaid/year=2024/month=01/part-0002.parquet
```

Watch the **small-files problem**: write reasonably large Parquet files (128 MB–1 GB)
or **compact** periodically — thousands of tiny files kill scan performance and cost.

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

## Reading archived data — yes, and several ways

Parquet-on-S3 is readable **without restoring to a database**:

| Tool | How | Best for |
|---|---|---|
| **AWS Athena** | serverless SQL over S3 (Glue Data Catalog); `SELECT … WHERE event_type=…` | ad-hoc queries, reporting, no infra |
| **DuckDB** | `SELECT * FROM read_parquet('s3://flow-archive/…')` — embedded, reads S3 directly | on-demand analysis from a laptop/job, very fast, cheap |
| **Spark / EMR / Trino** | distributed jobs | large-scale reprocessing / backfills |
| **Re-ingest to Postgres** | read Parquet → replay into a scratch/hot DB | full event replay / rebuilding a projection |

Two distinct access modes — decide and document which you support:

- **Query in place** (Athena/DuckDB) for analytics and inspection, without touching
  the operational DB. Reads the JSON `data`/`metadata` columns with SQL JSON
  functions.
- **Restore on demand**: re-ingest a batch back into a DB to *replay* it through the
  event store. Slower but gives full event-sourcing semantics.

Make explicit that **archived streams are not online-replayable** by the live
service until restored — so no read model or command path may depend on them.

Cataloging: register the S3 dataset in the **AWS Glue Data Catalog** (a crawler or
an explicit table) so Athena/Trino/Spark all see the same schema and partitions.

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

## Policies (S3 lifecycle, immutability, security, compliance)

- **Storage-class lifecycle**: S3 lifecycle rules transition objects by age —
  Standard → Standard-IA → Glacier → Glacier Deep Archive — matching access
  frequency to cost. Recent archive stays queryable; very old moves to the cheapest
  (slow-restore) tiers.
- **Immutability (WORM)**: enable **S3 Object Lock** (compliance/governance mode)
  so archived events can't be altered or deleted before a retention date — enforces
  the append-only, source-of-truth guarantee and satisfies audit/regulatory holds.
- **Retention & legal hold**: set a retention period per the compliance requirement
  (e.g. N years for financial data); legal holds override lifecycle expiry.
- **Encryption**: SSE-KMS at rest, TLS in transit; a dedicated KMS key for the
  archive with tight key policies.
- **Access control**: least-privilege IAM — archival job can **write**, analysts
  can **read** via Athena, almost nobody can **delete**. Separate the archive bucket
  from operational buckets.
- **GDPR / right-to-erasure vs WORM**: hard deletes conflict with Object Lock. Use
  **crypto-shredding** — encrypt per-subject data with a per-subject key and destroy
  the key to render it unreadable — instead of deleting locked objects. Design this
  in if personal data may be archived.
- **Cost controls**: partition pruning + compaction keep Athena scan costs down
  (Athena bills per TB scanned); columnar Parquet + partitions is what makes this
  cheap.
- **Catalog & schema versioning**: version the archive schema; if event shapes
  evolve, an Iceberg/Delta table or a schema field keeps old and new readable.
- **Verification & audit**: store checksums/manifests per batch; periodically verify
  restorability (a restore drill) — an archive you can't restore is not a backup.

## Applies only once it's worth it

Like the rest of this section, don't build archival up front. Introduce it when the
hot database is actually large enough to hurt performance or cost. If you expect
this from the start, **partition the RES tables by time early** — retrofitting
partitioning onto a huge table is the expensive path.
