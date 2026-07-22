# Infrastructure — Definition & Guidelines

How to provision and run the non-Rails RubyEventStore app (see
[running-res-without-rails.md](./running-res-without-rails.md)) on AWS, aligned
with Kantox Platform/SRE conventions.

Sources: Platform Team Onboarding Guide (Confluence `Cloud`), Kantox Flow
Monitoring Infra — Release Process Hub (Confluence `SSRE`).

---

## 1. Principles (Kantox Platform)

These are the team's stated principles — every decision below follows them:

- **Infrastructure as Code** — everything version-controlled and reproducible.
  No click-ops in the AWS console.
- **Security First** — least-privilege IAM, cross-account roles, secrets never in
  code or plain env.
- **Cost Consciousness** — right-size, autoscale, share NAT/networking; optimize
  without sacrificing reliability.
- **Documentation** — record decisions, processes, and runbooks.
- **Managed-first** — prefer AWS managed services over self-hosted stateful
  systems.

## 2. Platform decision — ECS vs EKS

**Default: Terraform + ECS Fargate + managed data services.**

Both ECS and EKS can run this app. The choice is a **trade-off between operational
cost and platform capability**, not a technical blocker. This app is 3 stateless
processes + 3 managed data services — exactly ECS Fargate's sweet spot: you define
a task, a `command`, and an autoscaling policy, with **no cluster to operate**. EKS
gives you more power but you own the cluster (upgrades, Karpenter, ArgoCD, RBAC,
CNI, operators). You should only pay that cost when you get something back for it.

At Kantox this is already an organizational default: **apps run on ECS**; **EKS is
reserved for the Data/ML ecosystem** (Karpenter + ArgoCD GitOps). So for this app,
ECS is the paved road unless Platform decides to fold it into their k8s platform.

### Decision table

| Criterion | Choose **ECS Fargate** | Choose **EKS (k8s)** |
|---|---|---|
| Operational ownership | AWS runs the control plane; nothing to patch | You own cluster upgrades, nodes, add-ons |
| Workload shape | A few stateless services (this app) | Many services / complex topologies |
| Team standard | Org default for apps (Kantox) | Team already operates k8s maturely |
| Advanced primitives | Not needed | Need CRDs/operators (e.g. OTel Operator), service mesh, sidecars |
| Event-driven autoscaling | Custom-metric Application Auto Scaling (works) | **KEDA** is the native fit (queue depth) |
| GitOps | Terraform + tags/PR flow | ArgoCD reconciliation is a first-class win |
| Portability / multi-cloud | AWS-coupled | Portable, avoids ECS lock-in |
| Marginal cost of one more app | Low | Low **only if** a k8s platform already exists |

**Rule of thumb**: pick EKS when you *gain* something concrete — a unified k8s
platform, operators/mesh, KEDA-as-standard, or portability — that **outweighs**
owning a cluster. Otherwise ECS.

### What stays fixed regardless of the above

| Layer | Choice | Rationale |
|---|---|---|
| Postgres, Redis, RabbitMQ | **Managed** (RDS / ElastiCache / Amazon MQ) | Never self-host stateful systems on ECS/k8s |
| Provisioning | **Terraform** | IaC; two-repo CI/CD (code repo + infra repo) |
| Runtime (this app, default) | **ECS Fargate** | Kantox app default; no cluster to operate |

> The Kubernetes appendix (§11) applies **only** if the EKS path is chosen.

## 3. Component → resource mapping

The app is 3 stateless process types + 3 stateful services:

| App component | AWS resource (Terraform) |
|---|---|
| web (Puma/Rack) | `aws_ecs_service` + `aws_ecs_task_definition`; `aws_lb` + target group + listener |
| consumer (Kicks/RabbitMQ) | `aws_ecs_service` (no LB); autoscale on queue depth |
| worker (Sidekiq) | `aws_ecs_service` (no LB); autoscale on queue depth |
| Event store | `aws_db_instance` / `aws_rds_cluster` (Postgres) + `aws_db_subnet_group`, storage autoscaling |
| Sidekiq broker | `aws_elasticache_replication_group` (Redis 7.2+, `maxmemory-policy noeviction`) |
| Inbound transport | `aws_mq_broker` (RabbitMQ; cluster in prod) |
| Config / secrets | `aws_secretsmanager_secret` (DATABASE_URL, REDIS_URL, RABBITMQ_URL) → injected into task defs |
| Network | reuse the account VPC / Transit Gateway hub-and-spoke; `aws_security_group` per service |

All three ECS services run the **same image**, differ only in `command`
(`puma` / `sneakers` / `sidekiq`) and their autoscaling policy.

## 4. Repository & module structure

Follow the two-repo model (application code vs. infrastructure), and the
per-environment Terraform layout used by `kantox-flow-monitoring-infra`:

```
<app>-infra/
├── terraform/
│   ├── environments/
│   │   ├── staging/         # backend.tf (S3 state), env tfvars
│   │   ├── preprod/
│   │   ├── production/
│   │   ├── bnpp-staging/
│   │   ├── bnpp-preprod/
│   │   ├── bnpp-prod/
│   │   ├── advdemo/
│   │   └── common/          # shared locals / naming
│   ├── modules/
│   │   ├── network/
│   │   ├── rds/
│   │   ├── elasticache/
│   │   ├── mq/
│   │   └── ecs-service/     # one reusable module, instantiated ×3
│   ├── ecs.tf               # the 3 services
│   ├── iam.tf               # task roles, execution roles (least privilege)
│   ├── data.tf              # remote state refs (infrastructure-datasources)
│   └── backend.tf           # S3 state backend (per environment)
└── docs/                    # runbooks, this file's app-specific notes
```

## 5. Naming & tagging conventions

- **Resource names**: `kantox-<service>-<component>-<environment>`
  (mirrors the alarm pattern `kantox-flow-{service}-{metric}-{environment}`).
  Example: `kantox-ecommerce-worker-production`.
- **Tags** on every resource: `Service`, `Environment`, `Tenant`
  (`kantox` | `bnpp`), `ManagedBy=terraform`, `Owner`, `CostCenter`.
- **Multi-account / multi-tenant**: 8 environments across the Kantox and BNPP
  tenants. Do not hardcode account ids — resolve via the environment's tfvars
  and remote state.

## 6. State management

- Terraform **state in S3, one bucket/key per environment** (with state locking).
- Reference shared infra (VPC, subnets, TGW, DNS) through **remote state**
  (`infrastructure-datasources`) in `data.tf` — never duplicate it.
- **One Terraform run per branch** (concurrency limit) to avoid state races.

## 7. CI/CD & release process

Adopt the modern two-track workflow:

- **App track** — build image → push to ECR → deploy ECS. Triggered by git tags
  (`staging`, `preprod`, `v*.*.*`). Causes a brief (1–2 min) rolling restart.
- **Infra track** — `terraform.yml`: **plan on PR creation, apply on merge**,
  environment auto-detected from the changed file path. No downtime.
- **Coordinated changes rule** (from SRE): when a change spans both app and
  metrics/alarms, **deploy the metric-emitting app first, verify it flows, then
  apply the alarm Terraform**. Alarms before metrics = false positives.
- **Hotfix**: branch `hotfix/<TICKET>-desc`, expedited review, tag (app) or merge
  (infra); ~10 min with pre-approval.

## 8. Observability (align with the app's OTel design)

The app emits OTLP (see the metadata contract + OTel plan). Wire it into the
Kantox stack, not a bespoke one:

- **Metrics** → VictoriaMetrics · **Logs** → Loki · **Dashboards** → Grafana
  (Okta auth) · **Collection** → OpenTelemetry.
- Ship OTLP → OTel Collector → VictoriaMetrics/Loki. On EKS use the **OpenTelemetry
  Operator** (already POC'd — Confluence `TW` "POC New observability platform").
- **CloudWatch alarms** via the infra track for ECS/RDS/queue baselines; alarm
  names validated (`kantox-<service>-<metric>-<environment>`).
- Propagate `traceparent` end to end so a request traces across web → RabbitMQ →
  Sidekiq (see [message-metadata-contract.md](./message-metadata-contract.md)).

## 9. Scaling guidelines

### Each service scales independently

web, consumer, and worker are **three separate services** (same image, different
`command`) — each with its own autoscaling policy, min/max, and metric. They do
not scale together:

- ECS: three `aws_ecs_service`, each with its own `aws_appautoscaling_target` + policy.
- EKS: three `Deployment`, each with its own HPA / KEDA `ScaledObject`.

Because the processes are decoupled by queues (consumer → queue → worker) and hold
no in-process state, each reacts to *its own* pressure at its own pace. Example: a
burst of inbound messages scales **consumer** up to drain RabbitMQ; that fills
Redis, which scales **worker** up to drain jobs; meanwhile **web** stays flat
because user traffic didn't change.

### Per-service scaling metric

| Service | Scale on | Not on | Typical min→max |
|---|---|---|---|
| **web** (Puma) | p95 latency / requests-per-target (ALB) + CPU fallback | — | 2 → 10 |
| **worker** (Sidekiq) | **Redis queue latency** (seconds waiting) or depth | CPU | 1 → 20 |
| **consumer** (Kicks) | **RabbitMQ messages-ready** (queue depth) | CPU | 1 → 8 |

- **Worker / consumer never scale on CPU** — always on queue depth/latency (jobs
  are usually IO-bound; CPU misleads).
- ECS: Application Auto Scaling on a **custom CloudWatch metric**. EKS: **KEDA**
  `redis` / `rabbitmq` scalers.
- Configure per service: metric, target threshold, min/max, **fast scale-out**,
  **slow scale-in** cooldown.

### Limits are set by the downstream resource that saturates first

Independent scaling forces you to bound each service by the shared resource it
would exhaust — not by the queue's demand:

- **worker `max`** ← Postgres connection pool (replicas × conns-per-replica must
  fit the RDS pool) and RDS IOPS.
- **consumer `max`** ← RabbitMQ throughput / prefetch.
- Compute each `max` from "what breaks first downstream", then let the queue metric
  drive within that ceiling.

### Time-to-ready must be minimal

Autoscaling only reacts *after* load appears, so a new replica's readiness time is
dead time where the backlog grows. Target **< 20–30 s** (ideally < 10 s for
workers). `time-to-ready = image pull + container start + app boot + readiness OK`.

Image (small = faster pull, the dominant cold-start cost):
- **Multi-stage build**: compile native gems in a build stage, ship a `ruby-slim`/
  alpine runtime with no toolchain.
- Runtime gems only (`bundle install --without development test`); layer-cache
  `bundle install` (copy Gemfile before code); no asset build at boot.

App boot:
- **Bootsnap** cache; no heavy initializers; lazy connections with short timeouts.
- Puma `preload_app!` for fast forking.
- **Readiness probe** checks real dependencies (DB/Redis/MQ reachable), separate
  from liveness — no traffic/jobs before truly ready.

Platform (speed up the pull):
- EKS: **Karpenter** warm nodes / image pre-pull. Fargate: **SOCI** lazy image
  loading. Both: **ECR pull-through cache**, same-region images.

### Data services

- **Postgres**: size for IOPS + connection pool, enable **storage autoscaling**
  (capacity is not the constraint; history grows append-only).
- **Redis**: `noeviction` — never let Sidekiq jobs be evicted.
- **Scale-in gracefully** on workers so in-flight jobs finish; rely on Sidekiq
  Enterprise `super_fetch` to recover any lost on scale-in.

## 10. Security

- **Access** via AWS SSO + **Granted CLI** for role assumption; cross-account IAM
  roles for deploys. No long-lived keys.
- **Least-privilege task roles** per service (worker needs RDS + Redis + MQ; web
  needs the same minus MQ publish if it doesn't publish).
- **Secrets** in Secrets Manager / SSM, injected at task launch — never in the
  image, tfvars, or git.
- Data services in **private subnets**, reachable only from the app security
  groups.

## 11. Kubernetes appendix (EKS path only)

If a platform decision puts this on EKS instead of ECS:

- **Deployments**: `web` (+ `Service`/`Ingress`), `consumer`, `worker`.
- **Autoscaling**: **Karpenter** for nodes, **KEDA** for queue-depth-driven pods,
  HPA (CPU/latency) for web.
- **GitOps**: **ArgoCD** — manifests live in the infra repo, Argo reconciles.
- **Config/secrets**: `ConfigMap` + External Secrets (→ Secrets Manager).
- **Stateful services**: still **managed** (RDS/ElastiCache/Amazon MQ) referenced
  from the cluster — do not run Postgres/RabbitMQ in-cluster without a platform
  mandate and an operator.
- **Observability**: OpenTelemetry Operator + Collector CR (per the Kantox POC).

## Required tooling

AWS CLI · Terraform · Docker · Granted CLI · (EKS: kubectl, K9s/OpenLens) —
per the Platform onboarding baseline.

---

## Open decisions to confirm with Platform/SRE

- **ECS vs EKS** for this app (default: ECS).
- Which **AWS accounts / tenants** it targets (Kantox only, or BNPP too → 8 envs).
- **RabbitMQ**: Amazon MQ vs. reuse an existing broker (Amazon MQ prod cluster is
  the costliest managed piece).
- Reuse existing **network/DNS** remote state (`infrastructure-datasources`) —
  confirm the module names.
