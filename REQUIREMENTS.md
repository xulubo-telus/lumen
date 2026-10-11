# Lumen-Triage-external — Requirements

## Overview

Autonomous PagerDuty incident triage workflow for n8n. Derived from the Casa team's production
`Lumen-Triage-v2` workflow as a generalized template for other teams to adopt the same auto-triage
pattern for their own GKE-hosted services.

**Status:** Template — inactive until all `YOUR_*` placeholders are replaced and credentials attached.

---

## Trigger

| Item | Detail |
|---|---|
| Protocol | HTTP POST webhook (n8n Webhook node, V3) |
| Event filter | `incident.triggered` and `incident.resolved` — all other PagerDuty event types are dropped |
| Deduplication (triggered) | 10-minute sliding window keyed on `incident_id`; duplicate events within the window are silently dropped |
| Deduplication (resolved) | 60-minute sliding window keyed on `incident_id` (separate dedup map `seenResolved`) |

---

## Functional Requirements

### 1. Ingest & Filter

- Receive raw PagerDuty webhook payload.
- Extract core incident fields: `incident_id`, `incident_title`, `incident_url`, `incident_status`,
  `urgency`, `service_id`, `service_name`, `occurred_at`, `event_type`.
- Respond `202 Accepted` immediately (non-blocking ack).
- Route on `event_type`:
  - `incident.triggered` → triage pipeline (sections 2–7).
  - `incident.resolved` → resolution learning loop (section 8).
  - All other event types → dropped.
- Deduplicate triggered events: skip `incident_id` seen within the last 10 minutes.
- Deduplicate resolved events: skip `incident_id` seen within the last 60 minutes.

### 2. PagerDuty Enrichment

- Fetch full incident record from the PagerDuty REST API v2 (`GET /incidents/{id}`).
- Fetch associated alerts (`GET /incidents/{id}/alerts`).
- Extract a Dynatrace Problem ID (`pid=…`) from alert payloads and PD links, if present.
- Normalize the incident object (handles single-incident and array response shapes).
- Retrieve up to 5 prior human resolution notes from the same incident (excluding Lumen's own
  auto-triage notes).
- Query PD incident history for the same service to detect recurrence.

#### Recurrence Tiers

| Tier | Prior count | Behaviour |
|---|---|---|
| *(novel)* | 0–2 | Full analysis |
| `recurring` | 3–9 | Full analysis + known-issue framing |
| `chronic` | 10–24 | Skip re-deriving root cause; state as established |
| `systemic` | 25+ | Chronic treatment + explicit escalation framing |

### 3. Dynatrace Enrichment

All Dynatrace queries use the tenant at `YOUR_DYNATRACE_TENANT`.

| Signal | API | Window |
|---|---|---|
| Linked problem | `/api/v2/problems/{pid}` | Exact problem ID from PD alert |
| Open problems | `/api/v2/problems` | −30 min to +15 min of incident creation |
| Deployment / change events | Grail DQL (Events) | −2 h to +15 min |
| Failing / slow spans | Grail DQL (Spans) | −60 min to +30 min |
| Service topology | Grail DQL (Entities) | −120 min to +15 min |
| Davis & config events | Grail DQL (Events) | −2 h to +15 min |
| Service metrics (p95, failures, requests) | Grail DQL (Timeseries) | −30 min to +15 min |

- Affected service IDs are collected from the linked problem, open-problems list, and GCP health scan
  results; capped at 30 services.
- Service topology and metrics are scoped to the collected affected-service ID set.

### 4. GCP Enrichment

All GCP calls use `YOUR_GCP_PROJECT_ID` and namespaces `YOUR_K8S_NAMESPACES_*`.

| Signal | Source | Window |
|---|---|---|
| Error logs | Cloud Logging API (`entries:list`) | −30 min to +15 min |
| Cloud SQL metrics | Cloud Monitoring | Configurable |
| Redis metrics | Cloud Monitoring | Configurable |
| GKE container/pod metrics | Cloud Monitoring | Configurable |
| GKE pod scheduling events | Cloud Logging | Incident window |
| GKE cluster audit log | Cloud Logging | Incident window |

- Error logs: severity `>= ERROR`, excludes `envoyproxy` and `istio-proxy` containers; page size 50.
- Infrastructure saturation flags: Cloud SQL / Redis utilization ≥ 85 %, GKE limit utilization ≥ 90 %,
  restart counts > 0, Redis evicted keys / blocked clients > 0, cache-hit ratio < 80 %.

### 5. Triage Context Assembly (`Build Triage Context`)

Curates all enrichment signals into a single structured context object:

- **Incident metadata** — id, number, title, status, urgency, priority, service, URL.
- **Service recognition** — whether the triggering PD service ID is in the team's known-services set.
- **Recurrence** — tier, prior count, first/last seen, history URL.
- **PD-linked Dynatrace problem** — curated problem record with evidence details and impact analysis.
- **Dynatrace problems** — up to 15 curated open problems; linked problem pinned first.
- **Dynatrace deployments** — up to 20 records.
- **Failing spans** — up to 20 records (endpoint, service, status code, trace ID, duration).
- **Key failing endpoints** — top 6 by failure count, merged from spans + evidence + server-side
  ranking; chronic-noise endpoints excluded (seed list + dynamic BQ-derived list).
- **Excluded chronic noise** — list of suppressed endpoints for transparency.
- **Service topology** — up to 60 service entity records.
- **Change events** — up to 20 Davis / availability / deployment / config events.
- **Service metrics** — p95, failure count, request count per affected service.
- **Error logs** — up to 15 curated log entries with error signatures.
- **Impacted apps** — derived from error-log signatures; fallback to top error-emitting apps.
- **Service health** — request count, failure count, 4xx/5xx count, p95 ms per service.
- **SLO evaluation** — p95 SLO met/breached per service (Davis baseline or 3 000 ms default);
  overall error percentage.
- **Infrastructure saturation** — Cloud SQL, Redis, GKE metric summaries + human-readable flags.
- **GKE scheduling** — pod events, cluster changes, flags.
- **GKE incident logs** — summarized GKE-level log context.
- **RUM sessions** — session count, error rate, 4xx/5xx sessions, flags.
- **IRIS notes** — TELUS IRIS platform root-cause / action-item notes for the same PD incident.
- **Prior resolution notes** — up to 5 human-written PD notes.
- **Data quality** — per-source success / failure / not-applicable status.
- **Links** — Dynatrace problem URL, service deep links (with global timeframe query), PagerDuty URL.

### 6. AI Triage Agent (Claude via FuelIX)

- Receives the full triage context.
- Classifies root cause category.
- Identifies the primary failing service and endpoint.
- Generates a structured incident analysis.
- Searches internal knowledge base for matching runbooks / past resolutions.
- Proposes a resolution with recommended actions.

### 7. Outputs (triggered path)

| Destination | Content |
|---|---|
| **BigQuery** `triage_incidents` | Full triage record per incident |
| **PagerDuty** custom fields | Root cause category, primary service, resolution summary |
| **PagerDuty** note | Human-readable triage summary |
| **Slack** | Incident summary message |
| **Lumen Console** | Reads from BigQuery rows |

### 8. Resolution Learning Loop (`incident.resolved` path)

A retrospective pipeline that runs when PagerDuty fires `incident.resolved`. Its purpose is to
close the feedback loop: score how well the original AI triage predicted the actual resolution and
feed useful human resolutions back into the knowledge base.

**Steps:**

1. **Get Resolved Incident** — fetch the full incident object from PagerDuty (`GET /incidents/{id}`).
2. **Get Resolution Notes** — fetch up to 50 PagerDuty notes (`GET /incidents/{id}/notes`).
3. **Build Triage Query / Fetch Original Triage** — query `YOUR_GCP_PROJECT_ID.lumen.triage_incidents`
   in BigQuery by `incident_number` to retrieve the AI-predicted root cause and next steps from the
   triggered-time triage.
4. **Build KB Resolution** — clean human-written notes (strip Lumen bot notes, process notes,
   link-only notes); compute MTTR; set `kb_useful = true` when substantive resolution text exists.
5. **Useful Resolution?** (branch)
   - **True** — embed the resolution text (FuelIX `text-embedding-3-small`), upsert the vector
     record to the FuelIX KB namespace `lumen-incidents` (category `incident-triage`), then score
     outcome match.
   - **False** — skip embedding/KB write; proceed directly to outcome scoring.
6. **Score Outcome Match** — AI agent compares the original predicted root cause/next steps against
   the actual human resolution; returns `matched` (0–1) and a ≤15-word `rationale`.
7. **Build Outcome Row / Insert Outcome Row** — write the outcome record to BigQuery
   `lumen.triage_outcomes` (always, regardless of `kb_useful`).

**Outputs (resolved path):**

| Destination | Content | Condition |
|---|---|---|
| **BigQuery** `triage_outcomes` | Outcome match score, MTTR, resolution details | Always |
| **FuelIX KB** `lumen-incidents` namespace | Resolution vector + metadata | Only when `kb_useful == true` |

No Slack messages or PagerDuty updates are posted on the resolved path.

---

## Non-Functional Requirements

| Concern | Requirement |
|---|---|
| Reliability | HTTP nodes retry up to 3× with 1 000 ms back-off; non-critical enrichment nodes use `onError: continueRegularOutput` so a failed signal never aborts the workflow |
| Latency | All external calls have a 30–35 s timeout; webhook ack is immediate |
| Idempotency | 10-minute dedup window prevents duplicate triage runs per incident |
| Data quality | Every enrichment source is tracked (ok / failed / not-applicable); failures are surfaced in the PD note |
| Noise suppression | Chronic-noise endpoints (seed list + BQ-derived, cross-incident diversity filter) are excluded from root-cause ranking |
| Observability | BigQuery analytics tables capture every triage run for the Lumen Console |

---

## Configuration Placeholders (must be replaced before activation)

| Placeholder | Where used | Description |
|---|---|---|
| `YOUR_DYNATRACE_TENANT` | All Dynatrace nodes | Dynatrace environment subdomain |
| `YOUR_GCP_PROJECT_ID` | GCP Logging, Monitoring | GCP project for error logs |
| `YOUR_GCP_LOGGING_PROJECT_ID` | GCP Logging | GCP project for log bucket queries |
| `YOUR_K8S_NAMESPACES_DQL` | Dynatrace Grail DQL | Namespace filter (DQL `in(…)` syntax) |
| `YOUR_K8S_NAMESPACES_GCP_OR` | GCP Logging filter | Namespace filter (GCP logging `OR` syntax) |
| `KNOWN_PD_SERVICE_IDS` | Build Triage Context | Set of PagerDuty service IDs owned by the team |
| `YOUR_OWN_SERVICE_PATTERN` | Build Triage Context | Regex token for relevance filtering |
| `YOUR_APP_PREFIX` | Build Triage Context | App-name prefix used in relevance checks |

---

## Required Credentials

All credentials must be attached in n8n before the workflow is activated.

| Node(s) | Credential type |
|---|---|
| Get PagerDuty Incident, Get PD Alerts, PD past incidents, PD notes | PagerDuty OAuth2 |
| Get Dynatrace Problems, Get Linked Dynatrace Problem | Dynatrace API token |
| Get Dynatrace Deployments, Get Failing Spans, Get Service Metrics, Get Service Topology, Get Davis & Change Events, Rank Failing Endpoints | Dynatrace platform bearer token (Grail) |
| Get Error Logs, GCP Monitoring (Cloud SQL, Redis, GKE), GKE pod events, GKE cluster audit | Google OAuth2 |
| Claude Triage Agent, KB search | FuelIX / Anthropic API key |
| BigQuery output nodes | Google OAuth2 / BigQuery credential |

---

## Integration Map

```
PagerDuty webhook
    └─► Ingest & filter
            ├─► incident.triggered
            │       └─► PagerDuty enrichment  ──────────────────────────────────┐
            │       └─► Dynatrace enrichment (problems / deployments / spans)   │
            │       └─► GCP enrichment (logs / metrics / GKE)                   │
            │       └─► IRIS enrichment                                          │
            │       └─► RUM enrichment                                           │
            │               └─► Build Triage Context ◄──────────────────────────┘
            │                       └─► Claude AI Triage Agent
            │                               ├─► BigQuery (triage_incidents)
            │                               ├─► PagerDuty (custom fields + note)
            │                               └─► Slack summary
            │
            └─► incident.resolved
                    └─► Get Resolved Incident + Resolution Notes (PagerDuty)
                            └─► Fetch Original Triage (BigQuery)
                                    └─► Build KB Resolution
                                            ├─► [kb_useful] Embed + Upsert to FuelIX KB
                                            └─► Score Outcome Match (Claude)
                                                    └─► Insert Outcome Row (BigQuery triage_outcomes)
```
