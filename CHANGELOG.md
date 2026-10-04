# Changelog

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
