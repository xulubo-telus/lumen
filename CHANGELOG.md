# Changelog

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
