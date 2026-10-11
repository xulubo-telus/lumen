# Requirements

## GKE Log-Based Metrics Alert Enrichment

**Status:** Implemented (2026-10-10)

### Problem

When GCP Cloud Monitoring fires a PagerDuty alert triggered by a log-based metric
(e.g., `logging.googleapis.com/user/<metric>`), the resulting incident has no linked
Dynatrace problem. The existing enrichment chain is Dynatrace-led and provides no
log-level evidence for these alerts. Operators receive a triage with empty or
irrelevant enrichment.

### Requirements

1. **Detect** whether an incoming PagerDuty alert was triggered by a GKE log-based
   metric, using signals from the PD alert payload and incident title.
2. **Retrieve** the GKE container log entries from Cloud Logging that drove the
   alert, scoped to a window of 1 hour before to 30 minutes after `occurred_at`.
3. **Summarize** the retrieved entries by container/severity counts, top message
   texts, and recurring error tokens for efficient AI consumption.
4. **Inject** the log summary as primary evidence into the Claude triage prompt,
   clearly labelled as the alert trigger.
5. **No-op** cleanly when the alert is not log-based (null summary, no prompt
   section rendered by Claude).
6. **No new credentials** — reuse the existing `googleOAuth2Api` credential
   (`Get Error Logs` pattern); `render.ps1` auto-wires it.
7. **No new placeholders** — use `YOUR_GCP_PROJECT_ID`, `YOUR_GCP_LOGGING_PROJECT_ID`,
   and `YOUR_K8S_NAMESPACES_GCP_OR` already handled by `render.ps1`.

### Implementation

Five nodes added to `Lumen-Triage-external.json` as a parallel branch from
`Extract Dynatrace Problem Ref`:

```
Extract Dynatrace Problem Ref
  ├─► Get Linked Dynatrace Problem   (existing)
  └─► Detect Alert Source            (Code)
        └─► Is GKE Log-Based Alert?  (IF, typeVersion 2.2)
              ├─ true  ► Build GKE Log Query (Code)
              │            └─► Get GKE Incident Logs (HTTP Request, POST, googleOAuth2Api)
              │                  └─► Summarize GKE Incident Logs (Code)
              └─ false ► (silent end, Build Triage Context receives null)
```

`Build Triage Context` reads `Summarize GKE Incident Logs` via try/catch
(no direct connection — safe when branch did not run).

`Claude Triage Agent` receives a dedicated prompt section that instructs Claude to
treat logs as primary evidence when present, or ignore the section when null.
