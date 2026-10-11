# Changelog

## 2026-10-11 15:00 (feat: Normalize GKE Incident Context node for Manual Triage Form path)

- Added `Normalize GKE Incident Context` Code node (position [1490, 1100])
- Reads from `Normalize Incidents` (always runs regardless of trigger path) and outputs
  flat fields: `incident_title`, `occurred_at`, `incident_id`, `status`, `urgency`, `pd_url`
- Fixes Manual Triage Form trigger path: `Extract Incident Context` (Set node) only runs
  after the PagerDuty webhook; this new node provides the same shape for all trigger paths
- `Detect Alert Source` and `Build GKE Log Query` now reference `Normalize GKE Incident Context`
- Connection chain: `Get PD Alerts → Normalize GKE Incident Context → Detect Alert Source`
  (mirrors debug flow; `Get PD Alerts` is the natural parent since both nodes need its data)

## 2026-10-11 16:15 (fix: genericAuthType httpHeaderAuth → httpBearerAuth for apps.dynatrace.com nodes)

- 10 nodes targeting `apps.dynatrace.com` had `genericAuthType: httpHeaderAuth` — changed to
  `httpBearerAuth` to match the Bearer token credential type used by the Dynatrace Platform API
- Affected: Get Dynatrace Deployments, Get Failing Spans, Get Service Metrics, Get Service Topology,
  Get Davis & Change Events, Scan Service Health, Get RUM Session Metrics, Resolve DT Workloads,
  Rank Failing Endpoints, Search Dynatrace Entities (External)

## 2026-10-11 16:00 (fix: BigQuery nodes use YOUR_BQ_PROJECT_ID instead of YOUR_GCP_PROJECT_ID)

- 5 BigQuery node URLs were using `YOUR_GCP_PROJECT_ID` (GKE/app project) instead of
  `YOUR_BQ_PROJECT_ID` (the separate converged-charging BQ project)
- Fixed: Insert BigQuery Row, Insert Outcome Row, Fetch Original Triage,
  Get Endpoint Noise Stats, Get Runbook Catalog

## 2026-10-11 15:30 (fix: Sync GKE Branch merge mode passThrough → chooseBranch)

- `Sync GKE Branch` (typeVersion 3): `mode: "passThrough"` is not valid in v3 — changed to
  `mode: "chooseBranch"` with `output: "input1"` (same semantics: wait for both inputs,
  pass through input 1 data from `Parse Runbook Catalog` to `Build Triage Context`)

## 2026-10-11 14:30 (fix: GKE nodes align with debug flow — use Extract Incident Context)

- `Detect Alert Source` and `Build GKE Log Query` in `Lumen-Triage-external.json` now
  reference `Extract Incident Context` (matching the debug flow), not `Normalize Incidents`
- `Detect Alert Source`: title read via `$('Extract Incident Context').first().json.incident_title`
- `Build GKE Log Query`: timestamp read via `inc.occurred_at` from `Extract Incident Context`
- `Extract Incident Context` (Set node, runs from webhook) outputs flat fields (`incident_title`,
  `occurred_at`) identical in shape to the debug workflow's Code node — safe to reference

## 2026-10-10 (fix: synchronize GKE branch with Build Triage Context via Merge node)

- Added **`Sync GKE Branch`** (Merge, passThrough/input1, position [10784, 752]) between
  `Parse Runbook Catalog` and `Build Triage Context`
- **Input 0**: `Parse Runbook Catalog` — data passed through to `Build Triage Context`
- **Input 1** (sync signal only, data discarded): `Summarize GKE Incident Logs` (GKE true path)
  AND `Is GKE Log-Based Alert?` false branch (non-GKE path)
- Guarantees `Build Triage Context` waits for the GKE branch to complete before executing,
  regardless of which path the IF takes; prevents the race condition where `Build Triage Context`
  could run before `Summarize GKE Incident Logs` finished

## 2026-10-10 (feat: PagerDuty nodes use predefinedCredentialType / pagerDutyOAuth2Api)

- Changed all 8 PagerDuty HTTP Request nodes in `Lumen-Triage-external.json` and
  2 nodes in `Lumen-GKE-Debug.json` from `genericCredentialType / httpHeaderAuth`
  to `predefinedCredentialType / pagerDutyOAuth2Api`
- Updated `render.ps1`: added `pagerDutyOAuth2Api` case to the `predefinedCredentialType`
  switch; removed the `api\.pagerduty\.com` match from the `genericCredentialType` branch

## 2026-10-10 (fix: correct PD alerts accessor in Detect Alert Source)

- Fixed `Detect Alert Source` in `Lumen-Triage-external.json`:
  `json?.incident?.alerts` → `json?.alerts`
- PD `/incidents/{id}/alerts` returns `{ alerts: [...] }` directly; the `.incident.`
  nesting never existed — `alerts` was always an empty array, so `hasLogMetric` was
  always `false` and the GKE branch never activated on real incidents
- Fix discovered by running the debug workflow (`Lumen-GKE-Debug.json`) against a
  live incident; merged back to the main template

## 2026-10-10 (fix: Build GKE Log Query uses logsink bucket instead of _Default)

- Updated `resourceNames` in `Build GKE Log Query` (both `Lumen-Triage-external.json` and `Lumen-GKE-Debug.json`)
  from `projects/YOUR_GCP_LOGGING_PROJECT_ID/locations/global/buckets/_Default/views/_AllLogs`
  to `projects/cio-logging-storage-1b866dc7/locations/northamerica-northeast1/buckets/logsink_bucket_kitchen_sink/views/_AllLogs`
- Matches the sink bucket already used by `Get Error Logs` and `Get GKE Pod Events`
- Re-rendered both patched output files

## 2026-10-10 (feat: render-gke.ps1 for debug workflow)

- Added `render-gke.ps1` — thin wrapper that calls `render.ps1 -Template Lumen-GKE-Debug.json`
- Accepts the same `-PropsFiles` parameter; forwards it directly to `render.ps1`
- Outputs `Lumen-GKE-Debug-patched.json`

## 2026-10-10 (feat: Lumen-GKE-Debug standalone debug workflow)

- Added `Lumen-GKE-Debug.json` — standalone n8n workflow for debugging GKE log-based alert triage
- 13-node linear flow:
  1. **Run Debug** (Manual Trigger)
  2. **Set Incident ID** (Set node — edit `pd_incident_id` value here before running)
  3. **Get PD Incident** (HTTP GET `/incidents/{id}`, PD httpHeaderAuth)
  4. **Get PD Alerts** (HTTP GET `/incidents/{id}/alerts`, PD httpHeaderAuth)
  5. **Extract Incident Context** (Code — normalises incident fields)
  6. **Detect Alert Source** (Code — detects log-based metric signal, extracts `metric_name`)
  7. **Is GKE Log-Based Alert?** (IF — true/false branch)
  8. **Get Log Metric Definition** (HTTP GET Cloud Logging, googleOAuth2Api, `continueOnFail`)
  9. **Build GKE Log Query** (Code — uses metric filter or broad fallback)
  10. **Get GKE Incident Logs** (HTTP POST `entries:list`, googleOAuth2Api)
  11. **Summarize GKE Incident Logs** (Code — groups by container/severity, top 30 messages)
  12. **Build AI Context** (Code — assembles structured prompt with triage questions)
  13. **Not A GKE Log Alert** (Set — false branch message)
- Updated `render.ps1` to accept `-Template` parameter (default: `Lumen-Triage-external.json`);
  output is `<template-basename>-patched.json`; usage: `.\render.ps1 -Template Lumen-GKE-Debug.json`
- Added `Lumen-GKE-Debug-patched.json` to `.gitignore`

## 2026-10-10 (feat: derive log filter from GCP metric definition)

- Added **`Get Log Metric Definition`** (HTTP Request GET, `googleOAuth2Api`, `continueOnFail`) between
  `Is GKE Log-Based Alert?` and `Build GKE Log Query`
- Calls `GET https://logging.googleapis.com/v2/projects/{YOUR_GCP_LOGGING_PROJECT_ID}/metrics/{metric_name}`
  to retrieve the exact log filter that feeds the triggering metric (e.g.
  `resource.type="k8s_container" AND severity>=ERROR AND ...`)
- **`Detect Alert Source`** updated: extracts `metric_name` from `alerts[0].body.details.incident.metric.type`
  (falls back to `alerts[0].body.details.metric.type`); returns `metric_name` instead of `log_filter_hint`
- **`Build GKE Log Query`** updated: reads `$('Get Log Metric Definition').first().json.filter` via try/catch;
  falls back to broad namespace filter when metric definition is unavailable (404, empty metric name, etc.)
- `Is GKE Log-Based Alert?` true branch now routes through `Get Log Metric Definition` → `Build GKE Log Query`
- `render.ps1` auto-wires `Get Log Metric Definition` to `Google account 35`; 123 total substitutions

## 2026-10-10 (feat: GKE log-based metrics alert enrichment branch)

- Added 5-node parallel branch to `Lumen-Triage-external.json` that activates when a PagerDuty
  alert is triggered by a GKE log-based metric (no linked Dynatrace problem)
- **`Detect Alert Source`** (Code): detects log-based metric signal from PD alert payload and
  incident title; sets `is_gke_log_alert` flag and `log_filter_hint`
- **`Is GKE Log-Based Alert?`** (IF): gates the branch; false path is a silent no-op
- **`Build GKE Log Query`** (Code): constructs Cloud Logging `entries:list` request scoped to
  ±1 h/30 min around `occurred_at`; uses existing `YOUR_GCP_PROJECT_ID`,
  `YOUR_GCP_LOGGING_PROJECT_ID`, `YOUR_K8S_NAMESPACES_GCP_OR` placeholders
- **`Get GKE Incident Logs`** (HTTP Request, POST, `googleOAuth2Api`): queries
  `https://logging.googleapis.com/v2/entries:list`; `render.ps1` auto-wires `Google account 35`
- **`Summarize GKE Incident Logs`** (Code): groups by container/severity, extracts error tokens,
  keeps top 30 entries truncated to 400 chars
- **`Build Triage Context`** patched: reads `Summarize GKE Incident Logs` via try/catch;
  adds `gke_incident_logs` field to returned context (null when branch did not run)
- **`Claude Triage Agent`** prompt patched: new section inserted before `## RUM` instructs
  Claude to treat log entries as primary evidence when `gke_incident_logs` is present
- Branch connects from `Extract Dynatrace Problem Ref` in parallel with `Get Linked Dynatrace Problem`
- No changes to `render.ps1`, properties files, or `.gitignore`

## 2026-10-10 (feat: lumen-triage-common.properties + new render.ps1 default)

- Created `lumen-triage-common.properties` with shared values (Dynatrace tenant, GKE cluster,
  namespaces, app name, credential names, GChat webhooks, BQ location, runbook repo, etc.)
- Environment-specific keys (GCP project IDs, OAuth client, BQ project, PD webhook path,
  workflow name, Google credential name) remain in the env-specific overlay file
- `render.ps1` default changed from `lumen-triage.properties` to
  `lumen-triage-common.properties, lumen-triage-np.properties`
- PR environment: `.\render.ps1 lumen-triage-common.properties, lumen-triage.properties`
- `lumen-triage-common.properties` added to `.gitignore` (contains real API keys)

## 2026-10-10 (feat: render.ps1 supports multiple properties files)

- `-PropsFiles` parameter (was `-PropsFile`) now accepts an array of file paths
- Files are loaded left-to-right; later files override earlier keys (Spring-style layering)
- Usage: `.\render.ps1 lumen-triage.properties, lumen-triage-np.properties`
- Header block prints each loaded properties file path for auditability

## 2026-10-10 (feat: dynamic namespace list in Lumen-Triage-external.json)

- Replaced `YOUR_K8S_NAMESPACE_1` / `YOUR_K8S_NAMESPACE_2` in `Lumen-Triage-external.json` with 4 context-aware placeholder tokens
  - `YOUR_K8S_NAMESPACES_DQL` (5 nodes — Dynatrace DQL `in()` filter)
  - `YOUR_K8S_NAMESPACES_GCP_OR` (2 nodes — Cloud Logging `namespace_name=(... OR ...)` filter)
  - `YOUR_K8S_NAMESPACES_GCP_EACH` (1 node — GCP link-builder with repeated `resource.labels.namespace_name=`)
  - `YOUR_K8S_NAMESPACES_JSARRAY` (1 node — JavaScript array fallback in GKE metrics query)
- `render.ps1` now reads `YOUR_K8S_NAMESPACES` (comma-separated) and expands it into all 4 formats
- Both `.properties` files updated: two `YOUR_K8S_NAMESPACE_*` keys merged into one `YOUR_K8S_NAMESPACES=ns1,ns2,...`

## 2026-10-10 (feat: render.ps1 for Lumen-Triage-external.json)

- Added `render.ps1` — patches `Lumen-Triage-external.json` into `Lumen-Triage-external-patched.json`
- Replaces all 17 `YOUR_*` infrastructure placeholders via raw string substitution
- Wires credentials into all 39 httpRequest/langchain nodes
- Accepts `-PropsFile` parameter (default: `lumen-triage.properties`)
- Added `Lumen-Triage-external-patched.json` to `.gitignore`

## 2026-10-06 11:30 (docs: add Lumen project overview link to USAGE.md)

- Added link to Lumen Project Overview artifact at the top of USAGE.md as a prerequisite read before n8n setup

## 2026-10-06 11:15 (feat: BigQuery project ID configurable via properties file)

- Replaced hardcoded `cio-converged-charging-np-72ca` (8 occurrences) in `Lumen-Triage-RCS.json` with `YOUR_BQ_PROJECT_ID`
- `patch-credentials.ps1` now substitutes all 8 occurrences via raw string replacement before JSON parsing

## 2026-10-06 11:00 (feat: workflow name configurable via properties file)

- Replaced `"name":"Lumen-Triage-external"` in `Lumen-Triage-RCS.json` with `N8N_WORKFLOW_NAME_PLACEHOLDER`
- Added `N8N_WORKFLOW_NAME=Lumen-Triage-external` to `lumen-triage.properties` under new "n8n Workflow Identity" section
- `patch-credentials.ps1` now substitutes the workflow name into the output file

## 2026-10-06 10:30 (feat: PagerDuty webhook path configurable via properties file)

- Replaced hardcoded UUID in PagerDuty Webhook node `path` with `N8N_PAGERDUTY_WEBHOOK_PATH_PLACEHOLDER`
- Added `N8N_PAGERDUTY_WEBHOOK_PATH` key to `lumen-triage.properties` (defaults to original UUID)
- `patch-credentials.ps1` now substitutes the path into the output file

## 2026-10-06 10:00 (refactor: template/output separation for workflow JSON)

- `Lumen-Triage-RCS.json` is now a clean template — no credentials wired, webhook URLs as placeholders
- `patch-credentials.ps1` reads the template and writes `Lumen-Triage-RCS-patched.json` (never overwrites template)
- `Lumen-Triage-RCS-patched.json` added to `.gitignore` (contains real credential names and webhook URLs)
- Import `Lumen-Triage-RCS-patched.json` into n8n; re-run the script any time properties change

## 2026-10-04 17:00 (fix: patch-credentials.ps1 crash on nodes without authentication property)

- Guard `$node.parameters.authentication` access with PSObject.Properties check
- Google Chat HTTP Request nodes have no `authentication` field; strict mode threw on access
- Script now completes cleanly: 41 nodes patched with all credential names filled

## 2026-10-04 16:30 (feat: replace Slack nodes with Google Chat webhook)

- Removed both `n8n-nodes-base.slack` nodes (required Slack OAuth credential)
- Renamed `Build Slack Message` → `Build Google Chat Message`; output key `slack_text` → `gchat_text`
- Added `Post Triage to Google Chat` (HTTP Request, POST to `GCHAT_WEBHOOK_TRIAGE_PLACEHOLDER`)
  - Body: `{ text: $json.gchat_text }` — Google Chat bold syntax (`*bold*`) is identical to Slack mrkdwn
- Added `Post Error to Google Chat` (HTTP Request, POST to `GCHAT_WEBHOOK_ERROR_PLACEHOLDER`)
  - Body: plain text error report with workflow/node/error/execution fields
- Google Chat webhooks use no n8n credential — auth is embedded in the URL
- Added `GCHAT_WEBHOOK_TRIAGE` and `GCHAT_WEBHOOK_ERROR` to `lumen-triage.properties`
- Updated `patch-credentials.ps1`: removed Slack wiring; added URL substitution for both webhooks

## 2026-10-04 16:00 (chore: rename workflow JSON to Lumen-Triage-RCS.json)

- Renamed `Lumen-Triage-ccs-ratingprofile.json` → `Lumen-Triage-RCS.json`
- Updated `patch-credentials.ps1` to reference new filename

## 2026-10-04 15:45 (fix: httpBearerAuth for Dynatrace Platform and FuelIX Vector nodes)

- Changed `genericAuthType` from `httpHeaderAuth` → `httpBearerAuth` for 13 nodes:
  - 10 Dynatrace Platform nodes (`apps.dynatrace.com/platform/`)
  - 3 FuelIX Vector nodes (`vectors.fuelix.ai`)
- PagerDuty (8 nodes) and IRIS (2 nodes) remain `httpHeaderAuth`
- Updated `patch-credentials.ps1` to use `httpBearerAuth` credential key for those two services
- Updated `lumen-triage.properties` comments to reflect correct credential types

## 2026-10-04 15:30 (feat: credential name wiring via properties file)

- Added `N8N_CRED_NAME_*` keys to `lumen-triage.properties` for all 8 credential types
  - DYNATRACE_LEGACY, DYNATRACE_PLATFORM, PAGERDUTY, GOOGLE_OAUTH2,
    FUELIX_OPENAI, FUELIX_VECTOR, SLACK, IRIS
- Added `patch-credentials.ps1` — reads names from properties, wires them into workflow JSON
  - Dynatrace Legacy nodes → `dynatraceApi` credential type
  - Dynatrace Platform nodes (`apps.dynatrace.com/platform/`) → `httpHeaderAuth`
  - PagerDuty/FuelIX vector/IRIS nodes → `httpHeaderAuth` (separate per-service credential)
  - Google OAuth2 nodes → `googleOAuth2Api`
  - LangChain + Embed nodes → `openAiApi`
  - Slack nodes → `slackApi`
- Applied patch: 3 Dynatrace Legacy nodes now wired to `Dynatrace account 7`

## 2026-10-04 14:00 (docs: Dynatrace platform token URL in USAGE.md)

- Updated USAGE.md credential table: Dynatrace API token now references https://myaccount.dynatrace.com/platformTokens

## 2026-10-03 (feat: runbook_catalog BigQuery table)

- Added `lumen.runbook_catalog` DDL to bigquery-schema.sql
  - Columns: `service` (normalized name), `file` (runbook filename), `repo_url`, `description`, `updated_at`
  - Seeded with initial entry: `ccs-ratingprofile-gateway` → `RunBook.md`
  - Workflow reads `SELECT service, file` at triage time; falls back to hardcoded seed if table is empty

## 2026-10-03 (fix: BigQuery null values — continued)

- **Build Detailed Analysis**: replaced all `.item.json` with `.first().json` for the five upstream node references
  - Root cause: `.item` is only defined in `runOnceForEachItem` context; in `runOnceForAllItems` mode it may be undefined, causing silent failures and `$json = {}` in Build BQ Row
  - `.first()` is the documented accessor for `runOnceForAllItems` Code nodes

## 2026-10-02 (fix: BigQuery null values)

- **Build Detailed Analysis**: changed `return record;` → `return [{ json: record }];`
  - Root cause: n8n `runOnceForAllItems` Code nodes need items wrapped as `[{ json: obj }]`;
    returning a plain object causes the next node to receive `$json = {}`, making all BQ columns empty/null
- **Build Outcome Row**: same fix — `return [{ json: { bq_body: {...} } }];`
  - Same pattern in the resolution path

## 2026-10-02 (session end)

### Lumen-Triage-ccs-ratingprofile.json — final build

- Rebuilt from `Lumen-Triage-external.json` with all `YOUR_*` placeholders substituted from `lumen-triage.properties`
- Redis nodes removed; `CloudSQL Metrics Summary` wired directly to `Build DT Workload Query`
- Runbook set to `https://github.com/telus/bil-ccs-ratingprofile-gateway/blob/stage/docs/RunBook.md`
- BigQuery project set to `cio-converged-charging-np-72ca` (separate from GCP monitoring project)
- BigQuery location set to `northamerica-northeast1` (3 occurrences)
- Numeric null fixes in `Build BQ Row`: `?? 0` default on all 8 REQUIRED integer fields
- `YOUR_RUM_APPLICATION_ID` intentionally left as-is (RUM not configured)
- USAGE.md updated with form URL, triggering instructions, configuration reference
