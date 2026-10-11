# Lumen-Triage-external — Technical Specification

## 1. Purpose

`Lumen-Triage-external` is an n8n workflow that provides autonomous, AI-assisted incident triage
for PagerDuty alerts. Derived from the Casa team's production `Lumen-Triage-v2` workflow as a
generalized template for other teams. A team adopting it configures the `YOUR_*` placeholders for
their own GKE project, Dynatrace tenant, and PagerDuty services, attaches credentials, and activates.

---

## 2. Runtime Environment

| Item | Detail |
|---|---|
| Orchestration | n8n (self-hosted or cloud) |
| Workflow file | `Lumen-Triage-external.json` |
| Activation | **Inactive by default** — must be activated manually after configuration |
| Rendering | `render.ps1` substitutes `YOUR_*` placeholders from a `.properties` file before import |
| Total nodes | 114 (42 HTTP Request, 46 Code, plus Set / IF / Webhook / Agent / Sticky) |

---

## 3. High-Level Architecture

Two independent pipelines share a common ingest stage, routed by `event_type`.

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

## 4. Node Implementation Details

### 4.1 Ingest

#### `PagerDuty Webhook`
- **Type:** Webhook (POST, n8n Webhook V2)
- **Path:** `/edb3eb11-7fda-45aa-bbb1-0d4c62d2c5db` (configure in PagerDuty as the V3 webhook destination)
- Receives the raw PagerDuty V3 envelope: `{ event: { event_type, occurred_at, data: { id, title, ... } } }`

#### `Extract Incident Context`
- **Type:** Set
- Maps flat variables from the webhook envelope:

| Output field | Source expression |
|---|---|
| `incident_id` | `$json.body.event.data.id` |
| `incident_title` | `$json.body.event.data.title` |
| `incident_url` | `$json.body.event.data.html_url` |
| `incident_status` | `$json.body.event.data.status` |
| `urgency` | `$json.body.event.data.urgency` |
| `service_id` | `$json.body.event.data.service.id` |
| `service_name` | `$json.body.event.data.service.summary` |
| `occurred_at` | `$json.body.event.occurred_at` |
| `event_type` | `$json.body.event.event_type` |

#### `Only Triggered Incidents`
- **Type:** IF (case-insensitive string equals)
- **Condition:** `$json.event_type == "incident.triggered"`
- TRUE → triage pipeline; no FALSE connection (non-triggered events dropped here)

#### `Is Resolved Event?`
- **Type:** IF (case-insensitive string equals)
- **Condition:** `$json.event_type == "incident.resolved"`
- TRUE → resolution learning loop; no FALSE connection

#### `Dedup Guard`
- **Type:** Code (uses `$getWorkflowStaticData('global')`)
- Maintains `store.seen` map keyed by `incident_id`; expires entries older than 10 minutes
- Drops items whose `incident_id` already appears in the map; passes all others through

#### `Dedup Resolve`
- Same pattern as Dedup Guard but uses `store.seenResolved` with a 60-minute window

---

### 4.2 PagerDuty Enrichment (triggered path)

All nodes use `predefinedCredentialType: pagerDutyOAuth2Api`. Retry: 3×, 1 000 ms back-off.

#### `Get PagerDuty Incident`
```
GET https://api.pagerduty.com/incidents/{{ $json.incident_id }}
Accept: application/vnd.pagerduty+json;version=2
```

#### `Normalize Incidents`
- **Type:** Code
- Handles three response shapes: `{incidents:[...]}`, `{incident:{...}}`, bare object
- Emits one item per incident with added `run_started_ms = Date.now()`

#### `Get PD Alerts`
```
GET https://api.pagerduty.com/incidents/{{ $json.incident_id }}/alerts
Accept: application/vnd.pagerduty+json;version=2
```
- `onError: continueRegularOutput`

#### `Extract Dynatrace Problem Ref`
- **Type:** Code
- Scans concatenated JSON of alerts + incident for Dynatrace problem ID patterns:
  - `?pid=<id>`, `/problems/problem/<id>`, `/problem/<id>`
- Also extracts any Dynatrace URL via regex
- Outputs `{ incident_id, dt_problem_id, dt_problem_url }`

#### `Get PD Past Incidents`
```
GET https://api.pagerduty.com/incidents/{{ $('Normalize Incidents').item.json.incident.id }}/past_incidents
    ?limit=50&total=true
From: raja.muddu@telus.com
Accept: application/vnd.pagerduty+json;version=2
```

#### `Pick Recurring Incident`
- **Type:** Code
- Normalises incident title signature (strips DT problem prefix, lowercases, removes punctuation)
- Selects the most recent past incident with a matching normalised title
- Outputs `past_pick_id` for the notes fetch below

#### `Get Past Incident Notes`
```
GET https://api.pagerduty.com/incidents/{{ $json.past_pick_id }}/notes?limit=20
From: raja.muddu@telus.com
Accept: application/vnd.pagerduty+json;version=2
```

---

### 4.3 Dynatrace Classic API Enrichment (triggered path)

Auth: `predefinedCredentialType: dynatraceApi`. Base: `https://YOUR_DYNATRACE_TENANT.live.dynatrace.com`.

#### `Get Linked Dynatrace Problem`
```
GET /api/v2/problems/{{ $json.dt_problem_id || 'NONE' }}
    ?fields=+evidenceDetails,+impactAnalysis,+recentComments,+affectedEntities
```
- `onError: continueRegularOutput`; skipped at context-build time if no `dt_problem_id` was extracted

#### `Get Dynatrace Problems`
```
GET /api/v2/problems
    ?from=<incident_created_at − 30 min, UTC ISO>
    &to=<incident_created_at + 15 min, UTC ISO>
    &fields=+evidenceDetails,+impactAnalysis,+recentComments,+affectedEntities
```
- `onError: continueRegularOutput`

#### `Collect Affected Services`
- **Type:** Code
- Merges SERVICE entity IDs (format `SERVICE-XXXXXXXXXXXXXXXX`) from three sources:
  1. Linked problem's `affectedEntities` + `rootCauseEntity`
  2. All open problems' `affectedEntities`
  3. Services with `failures > 0` or `errors4xx5xx > 0` from Scan Service Health
- Caps at 30 IDs; produces a DQL-ready string: `"SERVICE-AAA", "SERVICE-BBB", ...`

#### `Resolve RUM Application`
```
GET /api/v2/entities
    ?entitySelector=type(APPLICATION),entityName.contains("YOUR_APP_NAME")
    &pageSize=20
```
- Feeds Build RUM Query with application entity IDs

---

### 4.4 Dynatrace Grail (DQL) Enrichment (triggered path)

All nodes: `POST https://YOUR_DYNATRACE_TENANT.apps.dynatrace.com/platform/storage/query/v1/query:execute`
Auth: `genericCredentialType: httpBearerAuth` (platform token). Timeout: 35 000 ms.
All time windows anchored to `$('Normalize Incidents').item.json.incident.created_at`.

#### `Get Dynatrace Deployments`
- **Window:** −2 h to +15 min
```dql
fetch events
| filter in(k8s.namespace.name, YOUR_K8S_NAMESPACES_DQL)
| filter event.type == "CUSTOM_DEPLOYMENT" or contains(event.type, "DEPLOYMENT")
| sort timestamp desc
| limit 25
| fields timestamp, kind = event.kind, type = event.type, title = event.name,
         status = event.status, entity = dt.entity.service
```

#### `Get Failing Spans`
- **Window:** −60 min to +30 min
```dql
fetch spans
| filter in(k8s.namespace.name, YOUR_K8S_NAMESPACES_DQL)
| filter request.is_failed == true or http.response.status_code >= 400
| sort timestamp desc
| limit 25
| fields timestamp, trace_id = trace.id, span_name = span.name, service = service.name,
         service_id = dt.entity.service, endpoint = endpoint.name,
         method = http.request.method, status_code = http.response.status_code,
         db_statement = db.statement, failed = request.is_failed, duration
```

#### `Rank Failing Endpoints`
- **Window:** −60 min to +30 min
```dql
fetch spans
| filter in(k8s.namespace.name, YOUR_K8S_NAMESPACES_DQL)
| filter request.is_failed == true or http.response.status_code >= 400
| summarize { failures = count() },
    by: { service_id = dt.entity.service, endpoint = endpoint.name,
          method = http.request.method, status_code = http.response.status_code }
| filter isNotNull(endpoint)
| sort failures desc
| limit 15
```
Server-side aggregation; provides accurate failure counts beyond the 25-span sample limit of Get Failing Spans.

#### `Scan Service Health`
- **Window:** −60 min to +30 min
```dql
fetch spans
| filter in(k8s.namespace.name, YOUR_K8S_NAMESPACES_DQL)
| summarize {
    requests = count(),
    failures = countIf(request.is_failed == true),
    errors4xx5xx = countIf(http.response.status_code >= 400),
    p95 = percentile(duration, 95)
  }, by: { service_id = dt.entity.service }
| filter isNotNull(service_id)
| sort failures desc
| limit 50
```
Results feed Collect Affected Services and the SLO evaluation in Build Triage Context.

#### `Get Service Metrics`
- **Window:** −30 min to +15 min
- `affected_ids_dql` injected from Collect Affected Services output
```dql
timeseries {
  p95_response_time = percentile(dt.service.request.response_time, 95),
  failure_count = sum(dt.service.request.failure_count),
  request_count = sum(dt.service.request.count)
}, by: { dt.entity.service },
filter: in(dt.entity.service, <affected_ids_dql>)
```

#### `Get Service Topology`
- **Window:** −120 min to +15 min
- `affected_ids_dql` injected from Collect Affected Services output
```dql
fetch dt.entity.service
| filter in(id, <affected_ids_dql>)
| fields id, service = entity.name, tags, calls, called_by
| limit 100
```

#### `Get Davis & Change Events`
- **Window:** −2 h to +15 min
```dql
fetch events
| filter in(k8s.namespace.name, YOUR_K8S_NAMESPACES_DQL)
| filter event.kind == "DAVIS_EVENT" or event.kind == "AVAILABILITY_EVENT"
     or contains(event.type, "DEPLOYMENT") or contains(event.type, "CONFIG")
| sort timestamp desc
| limit 50
| fields timestamp, kind = event.kind, type = event.type, title = event.name,
         status = event.status, entity = dt.entity.service
```

#### `Get RUM Session Metrics`
- **Window:** −30 min to +15 min
- DQL built dynamically by Build RUM Query; skipped if no app entity IDs resolved
```dql
fetch user.sessions
| filter in(<RUM_APP_IDs>, dt.rum.application.entities)
| summarize
    sessions = countDistinctExact(dt.rum.session.id),
    sessionsWithErrors = countIf(error.count > 0),
    sessionsWith5xx = countIf(error.http_5xx_count > 0),
    sessionsWith4xx = countIf(error.http_4xx_count > 0),
    sum5xx = sum(error.http_5xx_count),
    totalErrors = sum(error.count)
```

#### `Resolve DT Workloads`
- **DQL** built by Build DT Workload Query:
  - If linked problem has CLOUD_APPLICATION entities → no-op DQL (`fetch dt.entity.cloud_application | limit 0`); names taken directly
  - If only SERVICE entities → Dynatrace entities API v2 with `runsOn` relationship:
    `type(CLOUD_APPLICATION),fromRelationships.runsOn(type(SERVICE),entityId("<id1>","<id2>",...))`

---

### 4.5 GCP Cloud Logging (triggered path)

All nodes: `POST https://logging.googleapis.com/v2/entries:list`
Auth: `predefinedCredentialType: googleOAuth2Api`.

#### `Get Error Logs`
- **Window:** incident_time −30 min to +15 min
- **Resource names:**
  - `projects/YOUR_GCP_LOGGING_PROJECT_ID/locations/global/buckets/_Default/views/_AllLogs`
  - `projects/cio-logging-storage-1b866dc7/locations/northamerica-northeast1/buckets/logsink_bucket_kitchen_sink/views/_AllLogs`
- **Filter:**
  ```
  resource.labels.project_id="YOUR_GCP_PROJECT_ID"
  AND resource.labels.namespace_name=(YOUR_K8S_NAMESPACES_GCP_OR)
  AND severity>="ERROR"
  AND -resource.labels.container_name="envoyproxy"
  AND -resource.labels.container_name="istio-proxy"
  AND timestamp>="<incident_time − 30 min>"
  AND timestamp<="<incident_time + 15 min>"
  ```
- `pageSize: 50`, `orderBy: "timestamp desc"`

#### `Get GKE Pod Events`
- **Window:** incident_time −30 min to +15 min
- **Resource names:** same two log buckets as Get Error Logs
- **Filter:**
  ```
  resource.type="k8s_event"
  AND resource.labels.project_id="YOUR_GCP_PROJECT_ID"
  AND resource.labels.namespace_name=(YOUR_K8S_NAMESPACES_GCP_OR)
  AND jsonPayload.reason=("Failed" OR "BackOff" OR "FailedMount" OR "FailedScheduling"
      OR "FailedCreatePodSandBox" OR "Unhealthy" OR "NodeNotReady")
  AND timestamp>="<incident_time − 30 min>"
  AND timestamp<="<incident_time + 15 min>"
  ```
- `pageSize: 200`, `orderBy: "timestamp desc"`

#### `Summarize GKE Pod Events`
- **Type:** Code
- Groups entries by `jsonPayload.reason`; strips pod-suffix from pod names to get workload names; extracts image names from pull-failure messages
- Outputs per-reason rollup: `{ reason, count, distinct_pods, distinct_workloads, workloads[], images[], sample_message }`

#### `Get GKE Cluster Audit Log`
- **Window:** incident_time −6 h to +15 min
- **Resource name:** `projects/YOUR_GCP_PROJECT_ID`
- **Filter:**
  ```
  logName="projects/YOUR_GCP_PROJECT_ID/logs/cloudaudit.googleapis.com%2Factivity"
  AND protoPayload.serviceName="container.googleapis.com"
  AND resource.labels.cluster_name="YOUR_GKE_CLUSTER_NAME"
  AND protoPayload.methodName=~"(UpdateCluster|UpdateNodePool|UpgradeNodePool|
      SetNodePoolManagement|SetNodePoolAutoscaling|SetLocations)"
  AND timestamp>="<incident_time − 6 h>"
  AND timestamp<="<incident_time + 15 min>"
  ```
- `pageSize: 20`, `orderBy: "timestamp desc"`

#### `Summarize GKE Cluster Changes`
- **Type:** Code
- Parses audit log entries; computes `minutes_before_incident` for each; outputs `{ cluster_changes[], flags[] }`

---

### 4.6 GKE Log-Based Alert Branch

Parallel branch from `Extract Dynatrace Problem Ref`. Detects incidents fired by a GCP log-based metric (no linked Dynatrace problem) and retrieves the raw log evidence.

#### `Detect Alert Source`
- **Type:** Code
- Returns `is_gke_log_alert = true` when:
  - Alert body contains `logging.googleapis.com/user/` or `log_based_metric`, OR
  - Title contains GKE/log-metric signals AND `dt_problem_id` is empty
- Extracts `metric_name` (strips `logging.googleapis.com/user/` prefix)

#### `Is GKE Log-Based Alert?`
- **Type:** IF — routes on `$json.is_gke_log_alert == true`

#### `Get Log Metric Definition`
```
GET https://logging.googleapis.com/v2/projects/YOUR_GCP_LOGGING_PROJECT_ID/metrics/{{ metric_name }}
```
- Returns the metric's own `filter` string, which Build GKE Log Query uses verbatim

#### `Build GKE Log Query`
- **Type:** Code
- Constructs the `entries:list` request body for Get GKE Incident Logs
- Uses metric's own filter if available; otherwise falls back to:
  ```
  resource.type="k8s_container"
  AND resource.labels.project_id="YOUR_GCP_PROJECT_ID"
  AND resource.labels.namespace_name=(YOUR_K8S_NAMESPACES_GCP_OR)
  AND severity>="WARNING"
  ```
- **Window:** incident_time −1 h to +30 min
- `pageSize: 100`, `orderBy: "timestamp desc"`

#### `Get GKE Incident Logs`
- **Method:** POST `https://logging.googleapis.com/v2/entries:list`
- **Resource name:** `projects/cio-logging-storage-1b866dc7/locations/northamerica-northeast1/buckets/logsink_bucket_kitchen_sink/views/_AllLogs`
- Body fully built by Build GKE Log Query

#### `Summarize GKE Incident Logs`
- **Type:** Code
- Groups entries by `container_name/severity`; extracts top 30 messages (≤400 chars each); tokenizes uppercase error codes (≥4 chars) from message text
- Outputs `{ container_groups[], top_messages[], error_tokens[] }`

---

### 4.7 GCP Cloud Monitoring (triggered path)

All nodes: `GET https://monitoring.googleapis.com/v3/projects/{{ project }}/timeSeries`
Auth: `predefinedCredentialType: googleOAuth2Api`.

Fan-out pattern: a preceding Code node (`CloudSQL Metric Types`, `Redis Metric Types`, `GKE Metric Types`) splits metric definitions into individual items; the HTTP node executes once per item; a subsequent Code node aggregates the responses back into a single `{ timeSeries: [...] }` object.

#### Cloud SQL

Metrics fetched (one request each):

| Metric type | Description |
|---|---|
| `cloudsql.googleapis.com/database/cpu/utilization` | CPU utilization (0–1) |
| `cloudsql.googleapis.com/database/memory/utilization` | Memory utilization (0–1) |
| `cloudsql.googleapis.com/database/disk/utilization` | Disk utilization (0–1) |
| `cloudsql.googleapis.com/database/postgresql/num_backends` | Active connections |
| `cloudsql.googleapis.com/database/postgresql/deadlock_count` | Deadlock count |

- **Resource filter:** `resource.labels.database_id = one_of("YOUR_GCP_PROJECT_ID:YOUR_CLOUDSQL_INSTANCE_1","YOUR_GCP_PROJECT_ID:YOUR_CLOUDSQL_INSTANCE_2")`
- **Window:** −30 min to +15 min; `alignmentPeriod=60s`, `perSeriesAligner=ALIGN_MEAN`
- **Saturation flags:** utilization ≥ 0.85, deadlock_count > 0

#### Redis

Metrics fetched:

| Metric type | Description |
|---|---|
| `redis.googleapis.com/stats/cpu_utilization_main_thread` | CPU |
| `redis.googleapis.com/stats/memory/usage_ratio` | Memory usage ratio (0–1) |
| `redis.googleapis.com/clients/connected` | Connected clients |
| `redis.googleapis.com/stats/cache_hit_ratio` | Cache-hit ratio (0–1) |
| `redis.googleapis.com/stats/evicted_keys` | Evicted key count |
| `redis.googleapis.com/clients/blocked` | Blocked client count |

- **Resource filter:** `resource.labels.instance_id = ends_with("/YOUR_REDIS_INSTANCE_NAME")`
- **Window:** −30 min to +15 min; `alignmentPeriod=60s`, `perSeriesAligner=ALIGN_MEAN`
- **Saturation flags:** usage_ratio ≥ 0.85, evicted_keys > 0, blocked > 0, cache_hit_ratio < 0.8

#### GKE

Metrics fetched:

| Metric type | Aligner | Reducer | Period |
|---|---|---|---|
| `kubernetes.io/container/cpu/limit_utilization` | ALIGN_MEAN | REDUCE_MAX | 300 s |
| `kubernetes.io/container/memory/limit_utilization` | ALIGN_MEAN | REDUCE_MAX | 300 s |
| `kubernetes.io/container/restart_count` | ALIGN_DELTA | REDUCE_SUM | 2 700 s |

- **Resource filter (priority order):**
  1. CLOUD_APPLICATION names from linked DT problem (Davis-curated)
  2. CLOUD_APPLICATION entities resolved from DT SERVICE IDs via `runsOn` relationship
  3. Workload names extracted from error logs (when no linked DT problem)
  4. Namespace-wide scan as final fallback
- Base filter: `resource.labels.cluster_name="YOUR_GKE_CLUSTER_NAME" AND resource.labels.namespace_name = one_of(<namespaces>)`
- When workload-scoped: appends `AND metadata.system_labels.top_level_controller_name = one_of(<workload_names>)`
- `groupByFields:` `resource.labels.namespace_name`, `metadata.system_labels.top_level_controller_name`
- **Saturation flags:** limit_utilization ≥ 0.90, restart_count > 0

---

### 4.8 Additional Enrichment (triggered path)

#### IRIS (TELUS incident management platform)

##### `IRIS Incident Details`
```
GET https://api.iris.telus.com/v1/incidents?pagerduty_id={{ incident.id }}&limit=1
```

##### `Resolve IRIS Incident Id`
- **Type:** Code — extracts `data[0].id` from IRIS response

##### `Get IRIS Incident Report`
```
GET https://api.iris.telus.com/v1/incidents/{{ irisIncidentId }}/report
```
Returns: `{ ai_root_cause, manual_root_cause, ai_executive_summary, manual_executive_summary, action_items[], actions_taken[], lessons_learned[], timeline_events[], links[] }`

##### `Extract IRIS Notes`
- **Type:** Code — prefers `manual_*` fields over `ai_*`; outputs `{ iris_notes, iris_primes, iris_incident_id, iris_web_url, iris_notes_available }`

#### BigQuery noise suppression

##### `Get Endpoint Noise Stats`
```sql
WITH endpoints AS (
  SELECT triage_id, root_cause_category,
    REGEXP_REPLACE(JSON_VALUE(ep, '$.endpoint'), r'^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+', '')
      AS endpoint
  FROM `YOUR_GCP_PROJECT_ID.lumen.triage_incidents`,
  UNNEST(JSON_EXTRACT_ARRAY(key_failing_endpoints_json)) AS ep
  WHERE triaged_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
    AND key_failing_endpoints_json IS NOT NULL
)
SELECT endpoint,
  COUNT(DISTINCT triage_id)          AS incident_count,
  COUNT(DISTINCT root_cause_category) AS category_diversity
FROM endpoints
WHERE endpoint IS NOT NULL
GROUP BY endpoint
HAVING incident_count >= 15 AND category_diversity >= 3
ORDER BY incident_count DESC
LIMIT 30
```
Endpoints appearing in 15+ incidents across 3+ different root cause categories are treated as chronic noise and excluded from the failing-endpoint ranking.

#### `Get Runbook Catalog`
```sql
SELECT service, file FROM `YOUR_GCP_PROJECT_ID.lumen.runbook_catalog`
```

---

### 4.9 Triage Context Assembly

#### `Build Triage Context`
- **Type:** Code (~45 KB)
- Aggregates all upstream enrichment into a single structured JSON object passed to the Claude agent

Key computed fields:

**`key_failing_endpoints`** (top 6 by failure count):
- Source 1: `Get Failing Spans` — endpoint, method, service_id, status_code, sample trace_id, failure count
- Source 2: evidence details from linked DT problem — endpoint path, HTTP method, per-evidence entity ID
- Source 3: `Rank Failing Endpoints` — server-side aggregated failure counts; overrides span counts when higher
- Endpoints matching the chronic-noise list (seed + dynamic from Get Endpoint Noise Stats) are removed and listed separately as `excluded_chronic_noise`
- Method stripping: embedded HTTP method prefix in `endpoint.name` (e.g. `POST /products/data`) is normalised to a bare path

**`recurrence`**: signature matching against `Get PD Past Incidents` results; tier assigned based on prior count (3–9 = recurring, 10–24 = chronic, 25+ = systemic)

**`slo`**: p95 SLO evaluated per affected service
- Davis baseline (`evidenceDetails.TRANSACTIONAL` items with `response time` in `displayName`)
- Fallback threshold: 3 000 ms when no Davis baseline exists
- Computes `p95_slo_met`, `p95_breaches[]`, `worst_p95_ms`, `error_pct`

**`infra.flags`** (up to 8): human-readable strings for saturated resources, e.g.
`"CloudSQL mydb cpu/utilization 91% (max)"`, `"GKE api-service cpu/limit_utilization 95% (max)"`

**`data_quality`**: per-source ok/failed/not-applicable counts; a source is "not applicable" when there was nothing to look up (no linked DT problem, no IRIS record, etc.)

---

### 4.10 AI Triage Agent (triggered path)

#### `Claude Triage Agent`
- **Type:** LangChain Agent node
- **Model:** Claude via FuelIX (`claude-sonnet-*` or configured model)
- Prompt is assembled from `Build Triage Context` output; includes dedicated sections for:
  1. Incident metadata + recurrence tier
  2. PD-linked Dynatrace problem with evidence and impact
  3. Open Dynatrace problems
  4. Deployments + change events
  5. Key failing endpoints (with Dynatrace deep links, method, status, count)
  6. Service metrics + SLO evaluation
  7. Error logs + error signatures
  8. Infrastructure saturation flags
  9. GKE scheduling events + cluster changes
  10. GKE incident logs _(primary evidence section, rendered only when `gke_incident_logs` is non-null — i.e., the GKE log-based alert branch ran)_
  11. RUM session summary
  12. IRIS root-cause + lessons learned
  13. Prior human resolution notes
  14. Data quality warnings
  15. KB similar-incident search results (retrieved via FuelIX vector search at prompt time)
- Returns structured JSON: `{ severity, root_cause_category, likely_root_cause, service_impact, blast_radius, confidence_score, next_steps[], ... }`

#### `Parse Triage JSON`
- **Type:** Code — strips optional markdown fences from LLM output; falls back to regex `{...}` extraction; returns safe defaults (`severity="unknown"`) on parse failure

---

### 4.11 Output Nodes (triggered path)

#### BigQuery — `Insert Triage Row`
```
POST https://bigquery.googleapis.com/bigquery/v2/projects/YOUR_BQ_PROJECT_ID/datasets/lumen/tables/triage_incidents/insertAll
```
Body built by `Build BQ Row`. Key columns: `schema_version`, `triage_id`, `incident_*`, `service_focus`, `severity`, `severity_score`, `root_cause_category`, `likely_root_cause`, `service_impact`, `blast_radius`, `confidence_score`, `linked_problem_*`, `top_failing_endpoint/status/url`, `key_failing_endpoints_json`, `failing_span_count`, `affected_service_count`, `deployment_count`, `total_requests/failures/4xx_5xx`, `error_pct`, `worst_p95_ms`, `p95_slo_*`, `next_steps_json/count`, `service_links_json`, `scan_wide`, `kb_match_count`, `sources_ok/total/failed_json`, `triaged_at`.

`Assert Triage Insert OK` checks for HTTP-200 responses that still contain per-row `insertErrors`; routes to error Slack channel on failure.

#### PagerDuty note — `Post Triage to PagerDuty`
```
POST https://api.pagerduty.com/incidents/{{ incident.id }}/notes
From: raja.muddu@telus.com
Accept: application/vnd.pagerduty+json;version=2
Body: { "note": { "content": <Build PD Note markdown text> } }
```
`Idempotency Guard` (Code) blocks this call if a note containing `"Lumen Auto-Triage"` already exists on the incident (prevents double-posting on re-delivery).

#### PagerDuty custom fields — `Update PD Custom Fields`
```
PUT https://api.pagerduty.com/incidents/{{ incident.id }}
Body: { "incident": { "custom_fields": [ { "name": "root_cause_category", "value": "..." }, ... ] } }
```

#### Slack — `Post Slack Message`
```
POST <YOUR_SLACK_WEBHOOK_URL>
Body: Slack Block Kit payload (built by Build Slack Message)
```
Includes: severity icon, service, confidence, category, root cause summary, failing endpoints, next steps, deep links.

---

### 4.12 Resolution Learning Loop (resolved path)

#### `Get Resolved Incident`
```
GET https://api.pagerduty.com/incidents/{{ $('Extract Incident Context').item.json.incident_id }}
Accept: application/vnd.pagerduty+json;version=2
```

#### `Get Resolution Notes`
```
GET https://api.pagerduty.com/incidents/{{ incident_id }}/notes?limit=50
From: raja.muddu@telus.com
Accept: application/vnd.pagerduty+json;version=2
```

#### `Build Triage Query` + `Fetch Original Triage`
```sql
SELECT likely_root_cause, next_steps_json, root_cause_category, severity, confidence_score
FROM `YOUR_GCP_PROJECT_ID.lumen.triage_incidents`
WHERE incident_number = '<number>'
ORDER BY triaged_at DESC
LIMIT 1
```
```
POST https://bigquery.googleapis.com/bigquery/v2/projects/YOUR_BQ_PROJECT_ID/queries
Body: { "query": <SQL>, "useLegacySql": false, "location": "YOUR_BQ_LOCATION", "timeoutMs": 20000 }
```

#### `Build KB Resolution`
- **Type:** Code
- Strips Lumen bot notes, process/status boilerplate, link-only notes (<30 chars) from PD note list
- Computes `mttr_minutes = (resolved_at − created_at) / 60 000`
- Sets `kb_useful = true` when at least one substantive human note remains

#### `Useful Resolution?`
- **Type:** IF — branches on `$json.kb_useful == true`

#### Embed + upsert (kb_useful = true branch)

##### `Embed KB Resolution`
```
POST https://api.fuelix.ai/v1/embeddings
Body: { "model": "text-embedding-3-small", "input": <resolution text> }
```

##### `Build KB Resolution Upsert` + `Upsert Resolution to KB`
```
POST https://vectors.fuelix.ai/canada-east1/v2/namespaces/lumen-incidents
Body: {
  "upsert_rows": [{
    "id": <PD incident number as uint>,
    "vector": <embedding array>,
    "text": <resolution text>,
    "attributes": {
      "category": "incident-triage",
      "incident_id": "...",
      "service": "...",
      "root_cause_category": "...",
      "resolution_notes": "...",
      "resolution_status": "resolved",
      "mttr_minutes": <float>,
      "source": "lumen"
    }
  }],
  "distance_metric": "cosine_distance"
}
```

#### `Score Outcome Match`
- **Type:** LangChain Agent (Claude via FuelIX)
- Prompt: compare original predicted root cause + next steps against actual human resolution notes
- Returns: `{ "matched": <float 0–1>, "rationale": "<≤15 words>" }`

#### `Parse Outcome Score`
- **Type:** Code — clamps `matched` to [0, 1]; extracts `match_rationale`

#### `Insert Outcome Row`
```
POST https://bigquery.googleapis.com/bigquery/v2/projects/YOUR_BQ_PROJECT_ID/datasets/lumen/tables/triage_outcomes/insertAll
```
Columns: `incident_id`, `incident_number`, `service`, `predicted_root_cause`, `actual_resolution`, `matched`, `match_rationale`, `mttr_minutes`, `resolved_at`, `kb_useful`.

---

### 4.13 FuelIX KB — Triggered Path (vector search)

#### `Build Retrieval Text`
- **Type:** Code
- Concatenates incident title, service name, linked problem title, top 5 failing endpoints, top 3 DT problem titles, top 3 error log messages (max 2 000 chars total)

#### `Embed Query`
```
POST https://api.fuelix.ai/v1/embeddings
Body: { "model": "text-embedding-3-small", "input": <retrieval text> }
```

#### `Retrieve Similar Incidents`
```
POST https://vectors.fuelix.ai/canada-east1/v2/namespaces/lumen-incidents/query
Body: {
  "rank_by": ["vector", "ANN", <embedding array>],
  "top_k": 5,
  "include_attributes": true,
  "filters": ["category", "Eq", "incident-triage"]
}
```

#### `Fuse KB Context`
- **Type:** Code
- Drops results that are the current incident itself; drops bot/process/link-only resolution notes; formats top 3 matches as numbered list: root cause + actual human fix (or predicted next steps if no fix recorded)

---

## 5. BigQuery Schema

### `lumen.triage_incidents` (key columns)

| Column | Type | Description |
|---|---|---|
| `triage_id` | STRING | UUID generated at run time |
| `schema_version` | STRING | Workflow schema version |
| `incident_id` / `incident_number` | STRING / INTEGER | PagerDuty identifiers |
| `incident_title` | STRING | PagerDuty title |
| `service_focus` | STRING | PagerDuty service name |
| `severity` | STRING | Claude-classified severity |
| `severity_score` | FLOAT | Numeric severity (0–1) |
| `root_cause_category` | STRING | Claude classification |
| `likely_root_cause` | STRING | Claude narrative |
| `service_impact` | STRING | Affected user/service description |
| `blast_radius` | STRING | Scope of impact |
| `confidence_score` | FLOAT | Claude confidence (0–1) |
| `linked_problem_id/url` | STRING | Dynatrace problem |
| `top_failing_endpoint` / `status` / `url` | STRING | Primary failing endpoint |
| `key_failing_endpoints_json` | STRING | JSON array of top endpoints |
| `failing_span_count` | INTEGER | Span count from DT |
| `affected_service_count` | INTEGER | Number of affected services |
| `deployment_count` | INTEGER | Recent deployments detected |
| `total_requests` / `total_failures` / `total_4xx_5xx` | INTEGER | Aggregated traffic metrics |
| `error_pct` | FLOAT | Overall error percentage |
| `worst_p95_ms` | FLOAT | Worst p95 latency (ms) |
| `p95_slo_met` | BOOLEAN | SLO status |
| `p95_slo_threshold_ms` | FLOAT | SLO threshold used |
| `next_steps_json` / `next_steps_count` | STRING / INTEGER | Claude recommended actions |
| `service_links_json` | STRING | Dynatrace service deep links |
| `scan_wide` | BOOLEAN | Whether metrics were org-wide |
| `kb_match_count` | INTEGER | KB similar incidents found |
| `sources_ok` / `sources_total` / `sources_failed_json` | INTEGER / STRING | Data quality |
| `triaged_at` | TIMESTAMP | Triage completion time |

### `lumen.triage_outcomes` (all columns)

| Column | Type | Description |
|---|---|---|
| `incident_id` / `incident_number` | STRING / INTEGER | PagerDuty identifiers |
| `service` | STRING | PagerDuty service name |
| `predicted_root_cause` | STRING | Original AI triage prediction |
| `actual_resolution` | STRING | Human PD resolution notes |
| `matched` | FLOAT | Outcome match score (0–1) |
| `match_rationale` | STRING | ≤15-word rationale from Claude |
| `mttr_minutes` | FLOAT | Minutes from created to resolved |
| `resolved_at` | TIMESTAMP | PagerDuty resolution time |
| `kb_useful` | BOOLEAN | Whether resolution was stored in KB |

---

## 6. External API Summary

| System | Method | Endpoint pattern | Auth |
|---|---|---|---|
| PagerDuty REST v2 | GET | `/incidents/{id}`, `/incidents/{id}/alerts`, `/incidents/{id}/notes`, `/incidents/{id}/past_incidents` | PagerDuty OAuth2 |
| PagerDuty REST v2 | POST | `/incidents/{id}/notes` | PagerDuty OAuth2 |
| Dynatrace classic v2 | GET | `/api/v2/problems`, `/api/v2/problems/{pid}`, `/api/v2/entities` | Dynatrace API token |
| Dynatrace Grail | POST | `/platform/storage/query/v1/query:execute` | Bearer token (platform) |
| GCP Cloud Logging | POST | `logging.googleapis.com/v2/entries:list` | Google OAuth2 |
| GCP Cloud Logging (metric) | GET | `logging.googleapis.com/v2/projects/{id}/metrics/{name}` | Google OAuth2 |
| GCP Cloud Monitoring | GET | `monitoring.googleapis.com/v3/projects/{id}/timeSeries` | Google OAuth2 |
| BigQuery | POST | `/bigquery/v2/projects/{id}/datasets/lumen/tables/{t}/insertAll` | Google OAuth2 |
| BigQuery | POST | `/bigquery/v2/projects/{id}/queries` | Google OAuth2 |
| FuelIX Embeddings | POST | `api.fuelix.ai/v1/embeddings` | FuelIX API key |
| FuelIX Vector Store | POST | `vectors.fuelix.ai/canada-east1/v2/namespaces/lumen-incidents` (upsert) | FuelIX API key |
| FuelIX Vector Store | POST | `vectors.fuelix.ai/canada-east1/v2/namespaces/lumen-incidents/query` | FuelIX API key |
| TELUS IRIS | GET | `api.iris.telus.com/v1/incidents`, `.../incidents/{id}/report` | IRIS credential |
| Slack | POST | Incoming Webhook URL | Webhook URL (secret) |

---

## 7. Resilience Design

| Mechanism | Detail |
|---|---|
| HTTP retries | Critical nodes: 3 attempts, 1 000 ms back-off |
| Graceful degradation | Non-critical enrichment uses `onError: continueRegularOutput`; failed signals produce empty results, pipeline continues |
| Deduplication | Triggered events: 10-min window; resolved events: 60-min window; both use n8n workflow static data (in-memory, persists across executions within the same process) |
| Silent-reject guard | `Assert Triage Insert OK` / `Assert Outcome Insert OK` detect BigQuery HTTP-200 responses containing per-row `insertErrors` |
| Idempotency guard | Code node checks existing PD notes for `"Lumen Auto-Triage"` before posting; blocks re-post on duplicate webhook delivery |
| Data quality reporting | Build Triage Context tracks every source as ok / failed / not-applicable; reported in PD note and stored in BigQuery |
| Noise suppression | Chronic-noise endpoint filter: hardcoded seed list + live BQ query (15+ incidents, 3+ root-cause categories over 90 days) |
| Service recognition guard | `KNOWN_PD_SERVICE_IDS` set prevents GKE/DT enrichment being treated as authoritative for unrecognized PD services |

---

## 8. Configuration Placeholders

All substituted by `render.ps1` from a `.properties` file before import into n8n.

| Placeholder | Nodes affected | Description |
|---|---|---|
| `YOUR_DYNATRACE_TENANT` | All Dynatrace HTTP nodes | Dynatrace environment subdomain |
| `YOUR_K8S_NAMESPACES_DQL` | All Grail DQL queries | `in(k8s.namespace.name, ...)` filter value |
| `YOUR_K8S_NAMESPACES_GCP_OR` | Cloud Logging filters | `(namespace1 OR namespace2 ...)` value |
| `YOUR_K8S_NAMESPACES_JSARRAY` | GKE Metric Types Code node | JavaScript array literal |
| `YOUR_GCP_PROJECT_ID` | Cloud Logging, BQ SQL | GCP project for logs and BQ queries |
| `YOUR_GCP_LOGGING_PROJECT_ID` | Log bucket resource names, metric URL | GCP project for log bucket |
| `YOUR_GKE_CLUSTER_NAME` | GKE Metrics, GKE Cluster Audit Log | GKE cluster name filter |
| `YOUR_BQ_PROJECT_ID` | All BigQuery insertAll/queries URLs | BigQuery project |
| `YOUR_BQ_LOCATION` | BigQuery query bodies | e.g. `northamerica-northeast1` |
| `YOUR_CLOUDSQL_INSTANCE_1/2` | CloudSQL Metric Types | Instance filter values |
| `YOUR_REDIS_INSTANCE_NAME` | Redis Metric Types | Instance filter value |
| `YOUR_APP_NAME` | Resolve RUM Application | DT entity name filter |
| `YOUR_RUM_APPLICATION_ID` | Build RUM Query (fallback) | DT RUM application entity ID |
| `KNOWN_PD_SERVICE_IDS` | Build Triage Context | `new Set([...])` literal — team's PD service IDs |
| `YOUR_OWN_SERVICE_PATTERN` | Build Triage Context | Regex token for relevance filtering |
| `YOUR_APP_PREFIX` | Build Triage Context | App-name prefix for relevance checks |

---

## 9. Onboarding Checklist

Before activating the workflow:

- [ ] Run `render.ps1` with a populated `.properties` file to substitute all `YOUR_*` placeholders
- [ ] Replace `KNOWN_PD_SERVICE_IDS` in `Build Triage Context` with your team's PD service IDs
- [ ] Replace `YOUR_OWN_SERVICE_PATTERN` and `YOUR_APP_PREFIX` with your service tokens
- [ ] Attach PagerDuty OAuth2 credential to all PD HTTP nodes
- [ ] Attach Dynatrace API token credential to classic-API nodes (`Get Dynatrace Problems`, `Get Linked Dynatrace Problem`, `Resolve RUM Application`)
- [ ] Attach Dynatrace platform bearer token to all Grail DQL nodes
- [ ] Attach Google OAuth2 credential to all GCP Logging, Monitoring, and BigQuery nodes
- [ ] Attach FuelIX API key to `Claude Triage Agent`, `Score Outcome Match`, `Embed Query`, `Embed KB Resolution`, `Retrieve Similar Incidents`, `Upsert to KB`, `Upsert Resolution to KB`
- [ ] Attach IRIS credential to IRIS nodes (or disable IRIS nodes if not used)
- [ ] Create BigQuery dataset `lumen` with tables `triage_incidents` and `triage_outcomes`
- [ ] Confirm Slack Incoming Webhook URL is set in `Post Slack Message`
- [ ] Send a test PagerDuty `incident.triggered` event and verify BigQuery row + PD note appear
- [ ] Resolve the test incident and verify BigQuery `triage_outcomes` row appears
- [ ] Activate the workflow
