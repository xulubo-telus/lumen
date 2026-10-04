# Lumen Triage — Usage Guide

## Prerequisites

- n8n instance running and accessible
- PagerDuty account with webhook permissions
- All placeholders in `lumen-triage.properties` filled and applied to the config JSON

---

## Importing the Workflow

1. Open n8n
2. **Workflows** → **Import from file**
3. Select `Lumen-Triage-ccs-ratingprofile.json`
4. The workflow imports as **Inactive** — do not activate yet

---

## Setting Up Credentials

Before activating, configure the following credentials in n8n (**Settings → Credentials**):

| Credential | Property | Used by |
|---|---|---|
| PagerDuty API key | `PAGERDUTY_API_KEY` | Get PagerDuty Incident, Get PD Alerts, Post Triage to PagerDuty |
| Google OAuth2 | `GCP_OAUTH_CLIENT_ID` / `GCP_OAUTH_CLIENT_SECRET` | GCP Monitoring (CloudSQL, GKE metrics), Cloud Logging, BigQuery |
| Dynatrace API token | Request platform token from https://myaccount.dynatrace.com/platformTokens | All Dynatrace REST and Grail (DQL) nodes |
| Anthropic / FuelIX API key | `OPENAI_API_KEY` | Claude Triage Agent, Outcome Chat Model |

---

## Wiring the PagerDuty Webhook

**Step 1 — Get the webhook URL from n8n**
1. Open the workflow
2. Click the **PagerDuty Webhook** node (first node)
3. Copy the **Production URL** (format: `https://<your-n8n>/webhook/<uuid>`)

**Step 2 — Register in PagerDuty**
1. PagerDuty → **Integrations** → **Generic Webhooks (V3)**
2. Click **New Webhook**
3. Paste the n8n Production URL
4. Subscribe to events: `incident.triggered` and `incident.resolved`
5. Scope to your service (`ccs-ratingprofile-gateway`) or all services

**Step 3 — Activate the workflow**
- In n8n, toggle the workflow from **Inactive → Active** (top-right switch)
- The webhook URL only accepts requests while the workflow is Active

---

## Triggering a Triage

### Automatic (normal operation)
1. An incident fires on `ccs-ratingprofile-gateway` in PagerDuty
2. PagerDuty sends an `incident.triggered` event to the n8n webhook
3. The workflow runs automatically — triage note posted to PagerDuty + Slack within ~60s

### Manual re-triage (any existing incident)
1. Open the workflow in n8n
2. Click the **Manual Triage Form** node (bottom-left of the canvas)
3. Copy the **Form URL** from the node panel — it looks like:
   `https://<your-n8n>/form/9d255e32-8ecc-4835-b917-ba90beb9a9d5`
4. Open that URL in a browser — a simple form with a **PagerDuty Incident ID** field appears
5. Enter the incident ID (e.g. `P1A2B3C`) and submit
6. The form rejoins the main flow at `Get PagerDuty Incident` and runs the full triage

> The workflow must be **Active** for the form URL to work. While inactive, use **Test step** on the node instead.

### Test without a real incident
- In PagerDuty webhook settings → **Send Test Event**
- Or trigger a low-urgency test incident on your PagerDuty service and resolve it immediately

---

## Monitoring Executions

- n8n → **Executions** (left sidebar) — shows each run with status, duration, and per-node output
- Failed executions are also posted to the Slack error channel (`On Error → Post Error to Slack`)

---

## What Happens on Resolution

When PagerDuty fires `incident.resolved`:
1. The workflow fetches resolution notes and the original triage row from BigQuery
2. Claude scores how well the predicted root cause matched the actual resolution
3. A `triage_outcomes` row is inserted into BigQuery
4. If the resolution is useful, it is embedded and upserted into the vector knowledge base

---

## Runbook

The workflow will suggest the following runbook when `ccs-ratingprofile-gateway` is the impacted service:

[RunBook.md](https://github.com/telus/bil-ccs-ratingprofile-gateway/blob/stage/docs/RunBook.md)

---

## Configuration Reference

See `lumen-triage.properties` for all configurable values and their descriptions.

| Placeholder | Value |
|---|---|
| `YOUR_DYNATRACE_TENANT` | `iyc06796` |
| `YOUR_GCP_PROJECT_ID` | `cdo-ccs-ratingprofile-np-e707` |
| `YOUR_GCP_LOGGING_PROJECT_ID` | `cdo-gke-private-pr-7712d7` |
| `YOUR_GKE_CLUSTER_NAME` | `private-na-ne1-001` |
| `YOUR_K8S_NAMESPACE_1` | `ccs-ratingprofile` |
| `YOUR_K8S_NAMESPACE_2` | `sapcc-ratingprofile` |
| `YOUR_CLOUDSQL_INSTANCE_1` | `ratingprofile` |
| `YOUR_APP_NAME` | `ccs-ratingprofile-gateway` |
| `YOUR_APP_PREFIX` | `ccs-ratingprofile` |
| `YOUR_ORG` | `telus` |
| `YOUR_RUNBOOK_REPO` | `bil-ccs-ratingprofile-gateway` |
| `YOUR_RUM_APPLICATION_ID` | *(not configured — RUM section inactive)* |
| `YOUR_BQ_LOCATION` | `northamerica-northeast1` |
