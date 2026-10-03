# Lumen-Triage-external — Flow Description

This is an **autonomous PagerDuty incident triage workflow** built in n8n. It is a generalized template derived from a production "Casa" workflow. The flow is organized into distinct phases.

> **Note:** The workflow is intentionally left **INACTIVE**. Every `YOUR_*` placeholder must be replaced with real tenant IDs, namespace names, and credentials before activation.

---

## 1. Ingest

**Nodes:** `PagerDuty Webhook` → `Extract Incident Context` → `Dedup Guard` → `Only Triggered Incidents`

- A **PagerDuty webhook** (V3, HTTP POST) receives all PagerDuty events.
- `Extract Incident Context` flattens the payload into key fields: `incident_id`, `incident_title`, `incident_url`, `incident_status`, `urgency`, `service_id`, `service_name`, `occurred_at`, `event_type`.
- `Dedup Guard` uses n8n workflow static data to track seen incident IDs in a 10-minute window — duplicate webhook deliveries are silently dropped.
- `Only Triggered Incidents` filters to **only** `incident.triggered` events; all other event types (acknowledge, resolve, etc.) are discarded here.

---

## 2. PagerDuty Enrichment

**Nodes:** `Get PagerDuty Incident` → `Normalize Incidents` → `Get PD Alerts` → `Extract Dynatrace Problem Ref` → `Get PD Notes` → `Get PD Past Incidents` → `Pick Recurring Incident` → `Get Past Incident Notes`

- Fetches the **full PagerDuty incident record** (responders, alerts, conference bridge, services) via PagerDuty REST API v2.
- `Normalize Incidents` ensures a consistent shape regardless of whether the API returned a single or list response, and attaches `run_started_ms`.
- `Get PD Alerts` fetches the incident's individual alerts (error details, alert bodies).
- `Extract Dynatrace Problem Ref` scans the alerts and incident body using regex to pull out a **Dynatrace Problem ID and URL** if referenced.
- `Get PD Notes`, `Get PD Past Incidents`, and `Pick Recurring Incident` retrieve resolution history and note threads from similar past incidents to inform the AI.

---

## 3. Dynatrace Enrichment

**Nodes:** `Get Linked Dynatrace Problem` → `Get Dynatrace Problems` → `Get Dynatrace Deployments` → `Get Failing Spans` → `Get Service Metrics` → `Get Error Logs` → `Get Service Topology` → `Get Davis & Change Events` → `Collect Affected Services`

- **Linked problem:** Fetches the specific DT problem extracted in step 2 (with evidence, impact, affected entities).
- **Problems window:** Fetches all Dynatrace problems in a `-30min / +15min` window around the incident creation time.
- **Deployments:** Queries Dynatrace Grail (DQL) for `CUSTOM_DEPLOYMENT` and deployment events in a `-2h / +15min` window across configured Kubernetes namespaces — helps correlate "who deployed before the incident?"
- **Failing spans:** Grail DQL query for failing/slow distributed traces (endpoint + DB statement + status code).
- **Service metrics, error logs, service topology, Davis & Change Events:** Additional Dynatrace data for the affected services.
- `Collect Affected Services` aggregates affected `SERVICE-*` entity IDs from problems, linked entity, and health scan results — builds the master list for downstream queries.

---

## 4. GCP / Infrastructure Enrichment

**Nodes:** `Scan Service Health` → `CloudSQL Metric Types` → `Get CloudSQL Metrics` → `Redis Metric Types` → `Get Redis Metrics` → `Get GKE Metrics` → `Get GKE Pod Events` → `Summarize GKE Pod Events` → `Get GKE Cluster Audit Log` → `Summarize GKE Cluster Changes`

- **Service health scan:** Runs a GCP/Dynatrace health check across services (failures, 4xx/5xx counts).
- **CloudSQL & Redis metrics:** Fetches metric series for databases using GCP Monitoring API.
- **GKE metrics & pod events:** Catches failures invisible to APM — pods stuck in `ImagePullBackOff`, `CrashLoopBackOff`, `FailedScheduling` (these never start, so have no APM signal). Also queries GKE cluster audit logs for node-pool upgrades and control-plane events in the 6h prior.

---

## 5. RUM (Real User Monitoring)

**Nodes:** `Resolve RUM Application` → `Build RUM Query` → `Get RUM Session Metrics` → `Summarize RUM Metrics`

- Resolves the application's Dynatrace RUM app **by name** (not hardcoded ID).
- Queries Grail for **real user session error rates** in the incident window.
- Confirms whether errors actually reached end users, or are backend-only.

---

## 6. External Entity Enrichment

**Nodes:** `Extract External Search Terms` → `Search Dynatrace Entities (External)` → `Parse Entity Match` → `Get Endpoint Noise Stats` → `Parse Endpoint Noise Stats` → `Resolve IRIS Incident Id` → `Get IRIS Incident Report` → `Extract IRIS Notes`

- Extracts search terms from the incident title/body to look up matching Dynatrace entities.
- Fetches endpoint noise stats to filter out known noisy/flapping signals.
- Integrates with **IRIS** (an internal incident management system) to pull any existing IRIS incident reports and notes for cross-system correlation.

---

## 7. Runbook Retrieval

**Nodes:** `Get Runbook Catalog` → `Parse Runbook Catalog`

- Fetches a runbook catalog and parses it — surfaced to the AI agent as relevant resolution playbooks.

---

## 8. Knowledge Base — Query (Similar Incidents)

**Nodes:** `Build Retrieval Text` → `Embed Query` → `Retrieve Similar Incidents` → `Fuse KB Context`

- Embeds the incident's triage context using an embedding model.
- Vector-searches a knowledge base for **similar past incidents** (nearest-neighbor lookup).
- `Fuse KB Context` merges retrieved matches into the prompt context.

---

## 9. Load Architecture Context

**Node:** `Load Architecture Context (Optional)`

- Optionally injects a static **architecture/topology map** of the affected services to give Claude structural awareness.

---

## 10. Build Triage Context

**Node:** `Build Triage Context`

- Aggregates **all enrichment signals** into a single structured context object: PagerDuty incident details, Dynatrace problems/deployments/traces, GCP metrics, GKE events, RUM data, IRIS data, KB similar incidents, runbook catalog, architecture map.
- Computes a best-guess **live debug trace link** into Dynatrace.

---

## 11. AI Triage (Claude via FuelIX)

**Nodes:** `Claude Triage Agent` → `Claude Chat Model`

- Sends the full triage context to **Claude** (Anthropic) via the FuelIX gateway.
- The system prompt instructs Claude to return **strict JSON** with:
  - `severity`
  - `root_cause_category`
  - `confidence`
  - `blast_radius`
  - `correlated_dynatrace_problems`
  - `next_steps`
  - A Slack-ready markdown summary block

---

## 12. Parse + Notify

**Nodes:** `Parse Triage JSON` → `Idempotency Guard` → `Build PD Note` → `Build Detailed Analysis` → `Build Slack Message`

- `Parse Triage JSON` extracts and validates the structured JSON from Claude's response.
- `Idempotency Guard` prevents double-posting to Slack/PagerDuty if the webhook retries.
- `Build PD Note` composes the PagerDuty note deterministically (not LLM markdown, which caused JSON parse failures previously).
- `Build Slack Message` composes the Slack summary.

---

## 13. Outputs

**Nodes:** `Post Triage to PagerDuty` → `Post Triage to Slack` → `Build BQ Row` → `Insert BigQuery Row` → `Build KB Record` → `Embed KB Record` → `Build KB Upsert Body` → `Upsert to KB`

- **PagerDuty:** Posts triage summary as an incident note and updates custom fields.
- **Slack:** Posts to the on-call channel (`#lumen-triage-feed`).
- **BigQuery:** Inserts a `triage_incidents` row for analytics and the Lumen Console dashboard.
- **Knowledge Base upsert:** Embeds and upserts the new triage record into the vector KB so future similar incidents benefit from it.

---

## 14. Resolution Tracking (Separate trigger path)

**Nodes:** `Is Resolved Event?` → `Dedup Resolve` → `Get Resolved Incident` → `Get Resolution Notes` → `Build Triage Query` → `Fetch Original Triage` → `Score Outcome Match` → `Outcome Chat Model` → `Parse Outcome Score` → `Build Outcome Row` → `Insert Outcome Row` → `Useful Resolution?` → `Build KB Resolution` → `Embed KB Resolution` → `Upsert Resolution to KB`

- When PagerDuty fires an **`incident.resolved`** event, a parallel path:
  - Fetches the resolution notes.
  - Retrieves the **original triage row** from BigQuery.
  - Uses Claude to **score how well the predicted root cause matched the actual resolution** (outcome scoring).
  - Inserts a `triage_outcomes` row into BigQuery.
  - If the resolution is deemed "useful," embeds and upserts it into the KB so it improves future retrievals.

---

## 15. Manual Re-Triage

**Nodes:** `Manual Triage Form` → `Prepare Manual Incident` → converges into `Get PagerDuty Incident`

- A form allows on-call engineers to submit a **PagerDuty incident ID manually** to re-run the full triage chain for any historical incident. The Dynatrace lookback window is derived from the incident's own `created_at`, so historical data is queried correctly.

---

## 16. Error Handling

**Nodes:** `On Error` → `Post Error to Slack`

- Any unhandled error in the main flow is caught and posted to a Slack error channel.

---

## Summary Flow Diagram

```
PD Webhook
    │
    ▼
Extract Context → Dedup Guard → Only Triggered?
                                      │ yes
                    ┌─────────────────┴──────────────────────────────────────┐
                    │  (parallel enrichment branches)                        │
                    │  PD:      Full incident, alerts, notes, past incidents  │
                    │  DT:      Problems, deployments, spans, topology        │
                    │  GCP:     CloudSQL, Redis, GKE pod events, audit logs   │
                    │  RUM:     Real user session error rates                 │
                    │  IRIS:    Cross-system incident reports                 │
                    │  Runbook: Catalog fetch                                 │
                    │  KB:      Vector search for similar past incidents      │
                    │  Arch:    Static topology map (optional)                │
                    └─────────────────┬──────────────────────────────────────┘
                                      │
                             Build Triage Context
                                      │
                             Claude Triage Agent
                                      │
                             Parse Triage JSON
                                      │
                             Idempotency Guard
                            ┌─────────┴──────────────────┐
                       PD Note                    BQ Row + KB Upsert
                       Slack Post
                                      │
               (on incident.resolved) │
                    Score Outcome → BQ Outcome Row → KB Resolution Upsert
```

---

## Key Integrations

| System | Purpose |
|--------|---------|
| PagerDuty | Incident trigger, enrichment, note posting, custom fields |
| Dynatrace | Problems, deployments, traces, metrics, RUM, service graph |
| GCP Monitoring | CloudSQL, Redis, GKE metrics |
| GKE Audit Logs | Cluster/node-pool changes, pod scheduling failures |
| IRIS | Cross-system incident correlation |
| Anthropic Claude (via FuelIX) | Triage reasoning, outcome scoring |
| BigQuery | `triage_incidents` and `triage_outcomes` tables for analytics |
| Slack | On-call channel notifications, error alerts |
| Vector KB | Embedding store for similar incident retrieval and resolution learning |
