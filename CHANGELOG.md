# Changelog

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
