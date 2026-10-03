-- BigQuery DDL for Lumen Triage workflow
-- Project: cio-converged-charging-np-72ca
-- Dataset: lumen
-- Location: northamerica-northeast1
--
-- Run these in BigQuery console or with: bq query --use_legacy_sql=false < bigquery-schema.sql

-- ============================================================
-- Table: lumen.triage_incidents  (main triage path)
-- ============================================================
CREATE TABLE IF NOT EXISTS `cio-converged-charging-np-72ca.lumen.triage_incidents`
(
  schema_version          INT64,
  triage_id               STRING NOT NULL,
  triaged_at              TIMESTAMP,
  source                  STRING,
  incident_id             STRING,
  incident_number         STRING,
  incident_title          STRING,
  incident_url            STRING,
  incident_status         STRING,
  incident_priority       STRING,
  incident_urgency        STRING,
  incident_created_at     TIMESTAMP,
  service_focus           STRING,
  severity                STRING,
  severity_score          FLOAT64,
  root_cause_category     STRING,
  likely_root_cause       STRING,
  service_impact          STRING,
  blast_radius            STRING,
  confidence              STRING,
  confidence_score        FLOAT64,
  linked_problem_id       STRING,
  linked_problem_display_id STRING,
  linked_problem_title    STRING,
  problem_url             STRING,
  problem_count           INT64,
  correlated_problem_ids  STRING,
  correlated_problem_titles STRING,
  top_failing_endpoint    STRING,
  top_failing_status      STRING,
  top_failing_url         STRING,
  key_failing_endpoints_json STRING,
  failing_span_count      INT64,
  affected_service_count  INT64,
  deployment_count        INT64,
  total_requests          INT64,
  total_failures          INT64,
  total_4xx_5xx           INT64,
  error_pct               FLOAT64,
  worst_p95_ms            INT64,
  p95_baseline_ms         INT64,
  p95_slo_threshold_ms    INT64,
  p95_slo_multiplier      FLOAT64,
  p95_slo_basis           STRING,
  p95_slo_met             BOOL,
  p95_breaches_json       STRING,
  next_steps_json         STRING,
  next_steps_count        INT64,
  service_links_json      STRING,
  scan_wide               BOOL,
  scanned_service_count   INT64,
  metric_service_count    INT64,
  kb_match_count          INT64,
  sources_ok              INT64,
  sources_total           INT64,
  sources_failed_json     STRING,
  infra_saturated         BOOL,
  infra_flags_json        STRING,
  infra_summary_json      STRING,
  detail_markdown         STRING,
  kb_hit                  BOOL,
  recurrence_prior_count  INT64,
  recurrence_chronic      BOOL,
  recurrence_tier         STRING,
  excluded_chronic_noise_json STRING,
  recurrence_signature    STRING,
  recurrence_first_seen   TIMESTAMP,
  recurrence_last_seen    TIMESTAMP,
  prior_notes_found       BOOL,
  prior_notes_count       INT64,
  prior_notes_chars       INT64,
  known_issue             BOOL,
  reused_prior_art        BOOL,
  triage_latency_ms       INT64,
  looker_dashboard_url    STRING,
  raw_context_json        STRING
)
OPTIONS (
  description = 'Lumen auto-triage records — one row per PagerDuty incident triage run'
);


-- ============================================================
-- Table: lumen.triage_outcomes  (resolution scoring path)
-- ============================================================
CREATE TABLE IF NOT EXISTS `cio-converged-charging-np-72ca.lumen.triage_outcomes`
(
  schema_version            INT64,
  incident_id               STRING,
  incident_number           STRING,
  incident_url              STRING,
  service_focus             STRING,
  root_cause_category       STRING,
  severity                  STRING,
  triage_confidence_score   FLOAT64,
  resolved_at               TIMESTAMP,
  created_at                TIMESTAMP,
  mttr_minutes              INT64,
  resolution_notes          STRING,
  resolution_note_count     INT64,
  predicted_next_steps      STRING,
  triage_matched_outcome    FLOAT64,
  match_rationale           STRING,
  recorded_at               TIMESTAMP
)
OPTIONS (
  description = 'Lumen triage outcome scores — one row per resolved PagerDuty incident'
);


-- ============================================================
-- Table: lumen.runbook_catalog  (runbook lookup)
-- ============================================================
-- Read by the workflow at triage time via:
--   SELECT service, file FROM `cio-converged-charging-np-72ca.lumen.runbook_catalog`
-- The workflow maps each row to { s: service, f: file } and uses it to suggest
-- a runbook URL built as: <RUNBOOK_BASE> + file
-- RUNBOOK_BASE = https://github.com/telus/bil-ccs-ratingprofile-gateway/blob/stage/docs/
--
-- service  — normalized service name (strip -production/-pr/-stage/-np suffixes).
--            Must be >= 8 chars for prefix-matching to activate.
-- file     — runbook filename relative to RUNBOOK_BASE (e.g. RunBook.md)
-- repo_url — optional: full base URL if the runbook lives in a different repo/branch
--            than the workflow default. Not read by the workflow today; for reference.
-- description — free-text notes on what this runbook covers.
-- updated_at  — when this entry was last reviewed / updated.
-- ============================================================
CREATE TABLE IF NOT EXISTS `cio-converged-charging-np-72ca.lumen.runbook_catalog`
(
  service     STRING NOT NULL,
  file        STRING NOT NULL,
  repo_url    STRING,
  description STRING,
  updated_at  TIMESTAMP
)
OPTIONS (
  description = 'Runbook catalog — maps normalized service names to runbook files on GitHub'
);

-- Seed initial entry for ccs-ratingprofile-gateway
INSERT INTO `cio-converged-charging-np-72ca.lumen.runbook_catalog`
  (service, file, repo_url, description, updated_at)
VALUES
  (
    'ccs-ratingprofile-gateway',
    'RunBook.md',
    'https://github.com/telus/bil-ccs-ratingprofile-gateway/blob/stage/docs/',
    'Primary runbook for ccs-ratingprofile-gateway incidents',
    CURRENT_TIMESTAMP()
  );
