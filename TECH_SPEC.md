# Lumen-Triage-external — Technical Specification

## 1. Purpose

`Lumen-Triage-external` is an n8n workflow that provides autonomous, AI-assisted incident triage
for PagerDuty alerts. It is a generalized template derived from the Casa team's production
`Lumen-Triage-v2` workflow. A team adopting it configures the placeholders for their own
GKE project, Dynatrace tenant, and PagerDuty services, attaches credentials, and activates.

---

## 2. Runtime Environment

| Item | Detail |
|---|---|
| Orchestration | n8n (self-hosted or cloud) |
| Workflow file | `Lumen-Triage-external.json` |
| Activation | **Inactive by default** — must be activated manually after configuration |
| Rendering | `render.ps1` substitutes `YOUR_*` placeholders from a `.properties` file before import |

---

## 3. High-Level Architecture

Two independent pipelines share a common ingest stage. Both are triggered by the same PagerDuty
webhook; routing is determined by `event_type`.

```
PagerDuty Webhook (POST)
    └─► Extract Incident Context
            ├─► [incident.triggered] ──► Dedup Guard (10 min)
            │       ├─► PagerDuty enrichment (parallel)
            │       ├─► Dynatrace enrichment (parallel)
            │       ├─► GCP enrichment (parallel)
            │       ├─► IRIS enrichment (parallel)
            │       └─► RUM enrichment (parallel)
            │               └─► Build Triage Context
            │                       └─► Claude Triage Agent
            │                               ├─► BigQuery triage_incidents
            │                               ├─► PagerDuty custom fields + note
            │                               └─► Slack summary
            │
            └─► [incident.resolved] ──► Dedup Resolve (60 min)
                    └─► PagerDuty (incident + notes)
                            └─► BigQuery (fetch original triage)
                                    └─► Build KB Resolution
                                            ├─► [kb_useful] FuelIX embed + upsert
                                            └─► Score Outcome Match (Claude)
                                                    └─► BigQuery triage_outcomes
```

---

## 4. Node Inventory

### 4.1 Ingest

| Node | Type | Purpose |
|---|---|---|
| `PagerDuty Webhook` | Webhook (POST) | Entry point; receives all PagerDuty V3 webhook events |
| `Extract Incident Context` | Set | Maps webhook payload fields to flat incident variables |
| `Only Triggered Incidents` | IF | Routes `event_type == incident.triggered` (true) |
| `Is Resolved Event?` | IF | Routes `event_type == incident.resolved` (true) |
| `Dedup Guard` | Code | 10-min dedup window (global static data `store.seen`); drops duplicate triggered events |
| `Dedup Resolve` | Code | 60-min dedup window (`store.seenResolved`); drops duplicate resolved events |

### 4.2 PagerDuty Enrichment (triggered path)

| Node | Type | API call |
|---|---|---|
| `Get PagerDuty Incident` | HTTP Request | `GET /incidents/{incident_id}` |
| `Normalize Incidents` | Code | Normalises single/array PD response; attaches `run_started_ms` |
| `Get PD Alerts` | HTTP Request | `GET /incidents/{incident_id}/alerts` |
| `Extract Dynatrace Problem Ref` | Code | Extracts `dt_problem_id` and `dt_problem_url` from alert payload |
| `Get PD Past Incidents` | HTTP Request | `GET /incidents` filtered by service; drives recurrence tier |
| `Get Past Incident Notes` | HTTP Request | `GET /incidents/{id}/notes` — up to 5 human notes |

### 4.3 Dynatrace Enrichment (triggered path)

| Node | Type | Source | Window |
|---|---|---|---|
| `Get Linked Dynatrace Problem` | HTTP Request | `/api/v2/problems/{pid}` | Exact linked problem |
| `Get Dynatrace Problems` | HTTP Request | `/api/v2/problems` | −30 min to +15 min |
| `Collect Affected Services` | Code | Merges entity IDs from linked problem + problems list + health scan; max 30 |
| `Get Dynatrace Deployments` | HTTP Request | Grail DQL — Events | −2 h to +15 min |
| `Get Failing Spans` | HTTP Request | Grail DQL — Spans | −60 min to +30 min |
| `Rank Failing Endpoints` | HTTP Request | Grail DQL — Spans (server-side aggregation) | Incident window |
| `Get Service Metrics` | HTTP Request | Grail DQL — Timeseries | −30 min to +15 min |
| `Get Service Topology` | HTTP Request | Grail DQL — Entities | −120 min to +15 min |
| `Get Davis & Change Events` | HTTP Request | Grail DQL — Events | −2 h to +15 min |
| `Scan Service Health` | HTTP Request | Grail DQL — Timeseries (request/failure/p95 per service) | −30 min to +15 min |

### 4.4 GCP Enrichment (triggered path)

| Node | Type | Source | Detail |
|---|---|---|---|
| `Get Error Logs` | HTTP Request | Cloud Logging `entries:list` | Severity ≥ ERROR, page 50, −30/+15 min |
| `CloudSQL Metrics Summary` | HTTP Request | Cloud Monitoring | CPU/connection/deadlock metrics |
| `Redis Metrics Summary` | HTTP Request | Cloud Monitoring | Memory, eviction, cache-hit metrics |
| `GKE Metrics Summary` | HTTP Request | Cloud Monitoring | CPU/memory limit utilization, restart counts |
| `GKE Metric Types` | Code | Derives GKE scope (namespace-scoped vs. wide) | — |
| `Get GKE Pod Events` | HTTP Request | Cloud Logging | Scheduling failures (Pending/OOMKilled/CrashLoop) |
| `Get GKE Cluster Audit Log` | HTTP Request | Cloud Logging | Cluster/node-pool control-plane changes |
| `Summarize GKE Pod Events` | Code | Aggregates pod events into flags | — |
| `Summarize GKE Cluster Changes` | Code | Aggregates cluster audit events into flags | — |

**GKE Log-Based Alert branch** (parallel from `Extract Dynatrace Problem Ref`):

| Node | Type | Purpose |
|---|---|---|
| `Detect Alert Source` | Code | Detects GKE log-based metric alerts from PD payload + title |
| `Is GKE Log-Based Alert?` | IF | Routes to log-fetch branch on true |
| `Build GKE Log Query` | Code | Constructs scoped Cloud Logging filter for the alert's metric |
| `Get GKE Incident Logs` | HTTP Request | Cloud Logging — retrieves log entries that fired the metric alert |
| `Summarize GKE Incident Logs` | Code | Groups by container/severity, extracts top messages and error tokens |

### 4.5 Additional Enrichment (triggered path)

| Node | Type | Source |
|---|---|---|
| `IRIS Incident Details` | HTTP Request | TELUS IRIS Public API — fetch incident by PD ID |
| `Resolve IRIS Incident Id` | Code | Extracts IRIS incident ID from response |
| `Get IRIS Incident Report` | HTTP Request | IRIS API — root-cause analysis, action items, lessons learned |
| `Extract IRIS Notes` | Code | Formats IRIS report for prompt injection |
| `Summarize RUM Metrics` | HTTP Request / Code | Dynatrace RUM session data (session count, error rate, 4xx/5xx) |
| `Get Endpoint Noise Stats` | HTTP Request | BigQuery — cross-incident endpoint diversity query |
| `Parse Endpoint Noise Stats` | Code | Converts BQ result to `dynamic_noise` list |
| `Pick Recurring Incident` | Code | Selects past PD incident to compare against (recurrence framing) |

### 4.6 Context Assembly

| Node | Type | Purpose |
|---|---|---|
| `Build Triage Context` | Code (~800 lines) | Merges all enrichment signals; computes key_failing_endpoints, recurrence tier, SLO evaluation, infra flags, Davis baseline RT deltas, data-quality report, and all deep links |

Key computed outputs:

- `key_failing_endpoints` — top 6, ranked by failure count, deduplicated across spans + evidence + server-side ranking; chronic-noise endpoints suppressed
- `slo` — p95 SLO evaluation per service using Davis baseline (or 3 000 ms default); overall error %
- `infra.flags` — human-readable saturation alerts (up to 8)
- `recurrence` — tier, prior count, first/last seen
- `data_quality` — per-source ok/failed/not-applicable counts

### 4.7 AI Triage Agent (triggered path)

| Node | Type | Model |
|---|---|---|
| `Claude Triage Agent` | LangChain Agent | Claude (via FuelIX) |

Prompt sections:

1. Incident metadata + recurrence tier
2. PD-linked Dynatrace problem (evidence, impact)
3. Open Dynatrace problems
4. Deployments / change events
5. Key failing endpoints (with Dynatrace deep links)
6. Service metrics + SLO evaluation
7. Error logs + error signatures
8. Infrastructure saturation flags
9. GKE scheduling events
10. GKE incident logs (primary evidence when log-based alert detected; section omitted otherwise)
11. RUM session summary
12. IRIS notes
13. Prior human resolution notes
14. Data quality warnings
15. KB search results (retrieved via FuelIX vector search at prompt time)

### 4.8 Outputs (triggered path)

| Node | Type | Destination | Detail |
|---|---|---|---|
| `Build BQ Row` | Code | — | Assembles BigQuery row from triage result |
| `Insert Triage Row` | HTTP Request | BigQuery `lumen.triage_incidents` | Streaming insert |
| `Build PD Note` | Code | — | Formats human-readable Markdown triage note |
| `Post PD Note` | HTTP Request | PagerDuty `POST /incidents/{id}/notes` | Posts note to incident |
| `Update PD Custom Fields` | HTTP Request | PagerDuty custom fields API | Root cause category, service, summary |
| `Build Slack Message` | Code | — | Formats Slack Block Kit message |
| `Post Slack Message` | HTTP Request | Slack Incoming Webhook | Posts to team channel |

### 4.9 Resolved Path (learning loop)

| Node | Type | Purpose |
|---|---|---|
| `Get Resolved Incident` | HTTP Request | `GET /incidents/{id}` — full resolved incident |
| `Get Resolution Notes` | HTTP Request | `GET /incidents/{id}/notes?limit=50` |
| `Build Triage Query` | Code | SQL to fetch original triage from `lumen.triage_incidents` by `incident_number` |
| `Fetch Original Triage` | HTTP Request | BigQuery `POST /queries` |
| `Build KB Resolution` | Code | Cleans notes; computes MTTR; sets `kb_useful` |
| `Useful Resolution?` | IF | Branches on `kb_useful == true` |
| `Embed KB Resolution` | HTTP Request | FuelIX Embeddings API — `text-embedding-3-small` |
| `Build KB Resolution Upsert` | Code | Assembles vector record |
| `Upsert Resolution to KB` | HTTP Request | FuelIX vector store `POST /namespaces/lumen-incidents` |
| `Score Outcome Match` | LangChain Agent | Claude — returns `{"matched": 0–1, "rationale": "…"}` |
| `Parse Outcome Score` | Code | Clamps score to [0,1]; extracts rationale |
| `Build Outcome Row` | Code | Assembles BigQuery outcome row |
| `Insert Outcome Row` | HTTP Request | BigQuery `lumen.triage_outcomes` streaming insert |

---

## 5. Data Flow — Triggered Path

```
PD Webhook payload
  → flat incident variables (incident_id, service_id, event_type, …)
  → [parallel enrichment] → all signals collected in Build Triage Context
  → structured context JSON (incident, recurrence, dynatrace_problems,
      key_failing_endpoints, slo, infra, gke_scheduling, rum, iris_notes, …)
  → Claude prompt (FuelIX)
  → triage result (root_cause_category, primary_service, analysis, resolution)
  → BigQuery row  →  triage_incidents table
  → PD note       →  incident timeline
  → PD fields     →  incident custom fields
  → Slack message →  team channel
```

---

## 6. Data Flow — Resolved Path

```
PD Webhook payload (incident.resolved)
  → incident_id, incident_number
  → PD: full incident + up to 50 notes
  → BigQuery: SELECT original AI triage row by incident_number
  → Build KB Resolution:
      - strip bot/process/link-only notes
      - compute MTTR = resolved_at − created_at (minutes)
      - kb_useful = true if ≥1 substantive human note
  → [if kb_useful]
      FuelIX embed (text-embedding-3-small)
      → vector upsert to lumen-incidents namespace
          {id, embedding, text, category, service,
           root_cause_category, resolution_notes,
           resolution_status="resolved", mttr_minutes, source="lumen"}
  → Score Outcome Match (Claude):
      compare predicted root cause + next steps vs. actual resolution
      → {matched: float, rationale: string}
  → BigQuery triage_outcomes:
      {incident_id, incident_number, service, predicted_root_cause,
       actual_resolution, matched, match_rationale, mttr_minutes,
       resolved_at, kb_useful}
```

---

## 7. BigQuery Schema

### `lumen.triage_incidents`

| Column | Type | Source |
|---|---|---|
| `incident_id` | STRING | PagerDuty |
| `incident_number` | INTEGER | PagerDuty |
| `incident_title` | STRING | PagerDuty |
| `service` | STRING | PagerDuty |
| `urgency` | STRING | PagerDuty |
| `root_cause_category` | STRING | Claude |
| `primary_service` | STRING | Claude |
| `primary_endpoint` | STRING | Claude |
| `analysis` | STRING | Claude (structured analysis text) |
| `recommended_actions` | STRING | Claude |
| `recurrence_tier` | STRING | Build Triage Context |
| `slo_p95_met` | BOOLEAN | Build Triage Context |
| `error_pct` | FLOAT | Build Triage Context |
| `data_quality_sources_ok` | INTEGER | Build Triage Context |
| `data_quality_sources_failed` | INTEGER | Build Triage Context |
| `run_started_ms` | INTEGER | Normalize Incidents |
| `created_at` | TIMESTAMP | PagerDuty |

### `lumen.triage_outcomes`

| Column | Type | Source |
|---|---|---|
| `incident_id` | STRING | PagerDuty |
| `incident_number` | INTEGER | PagerDuty |
| `service` | STRING | PagerDuty |
| `predicted_root_cause` | STRING | Original triage row |
| `actual_resolution` | STRING | Human PD notes |
| `matched` | FLOAT | Score Outcome Match (0–1) |
| `match_rationale` | STRING | Score Outcome Match |
| `mttr_minutes` | FLOAT | Build KB Resolution |
| `resolved_at` | TIMESTAMP | PagerDuty |
| `kb_useful` | BOOLEAN | Build KB Resolution |

---

## 8. External API Reference

| System | Endpoints used | Auth |
|---|---|---|
| PagerDuty REST API v2 | `/incidents/{id}`, `/incidents/{id}/alerts`, `/incidents/{id}/notes`, `/incidents` (list) | PagerDuty OAuth2 |
| Dynatrace classic API | `/api/v2/problems`, `/api/v2/problems/{pid}` | Dynatrace API token |
| Dynatrace Grail (platform) | `/platform/storage/query/v1/query:execute` | Bearer token |
| GCP Cloud Logging | `logging.googleapis.com/v2/entries:list` | Google OAuth2 |
| GCP Cloud Monitoring | `monitoring.googleapis.com/v3/projects/{id}/timeSeries` | Google OAuth2 |
| BigQuery | `/bigquery/v2/projects/{id}/datasets/lumen/tables/{t}/insertAll`, `/queries` | Google OAuth2 |
| FuelIX Embeddings | `api.fuelix.ai/v1/embeddings` | FuelIX API key |
| FuelIX Vector Store | `vectors.fuelix.ai/canada-east1/v2/namespaces/lumen-incidents` | FuelIX API key |
| TELUS IRIS | IRIS Public API (incident lookup + report) | IRIS credential |
| Slack | Incoming Webhook URL | Webhook URL (secret) |

---

## 9. Resilience Design

| Mechanism | Detail |
|---|---|
| Retries | Critical HTTP nodes: up to 3 attempts, 1 000 ms back-off |
| Graceful degradation | Non-critical enrichment nodes set `onError: continueRegularOutput` — a failed signal produces an empty result and the pipeline continues |
| Deduplication | Prevents duplicate triage/outcome runs within the dedup window using n8n workflow static data (in-memory, survives between executions within the same process) |
| Data quality reporting | `Build Triage Context` tracks every source (ok / failed / not-applicable); failures are surfaced in the PD note and stored in BigQuery |
| Noise suppression | Chronic-noise endpoints filtered before ranking: seed list + dynamic list derived from BQ cross-incident endpoint-diversity query |
| Service recognition guard | `KNOWN_PD_SERVICE_IDS` gates whether GKE/Dynatrace enrichment is treated as relevant; prevents confident-sounding noise for unrecognized PD services |

---

## 10. Onboarding Checklist

Before activating the workflow:

- [ ] Run `render.ps1` with a populated `.properties` file to substitute all `YOUR_*` placeholders
- [ ] Replace `KNOWN_PD_SERVICE_IDS` in `Build Triage Context` with your team's PD service IDs
- [ ] Replace `YOUR_OWN_SERVICE_PATTERN` and `YOUR_APP_PREFIX` with your service tokens
- [ ] Attach PagerDuty OAuth2 credential to all PD HTTP nodes
- [ ] Attach Dynatrace API token credential to classic-API nodes
- [ ] Attach Dynatrace platform bearer token to all Grail DQL nodes
- [ ] Attach Google OAuth2 credential to all GCP Logging, Monitoring, and BigQuery nodes
- [ ] Attach FuelIX API key to Claude Triage Agent, Score Outcome Match, and Embed nodes
- [ ] Attach IRIS credential to IRIS nodes (or disable IRIS nodes if not used)
- [ ] Create BigQuery dataset `lumen` with tables `triage_incidents` and `triage_outcomes`
- [ ] Verify Slack Incoming Webhook URL is configured
- [ ] Send a test PagerDuty `incident.triggered` event and confirm BigQuery row + PD note appear
- [ ] Activate the workflow
