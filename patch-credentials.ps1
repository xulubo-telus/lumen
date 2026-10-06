# patch-credentials.ps1
# Reads the workflow template (Lumen-Triage-RCS.json) and the values in
# lumen-triage.properties, then writes a ready-to-import file:
#   Lumen-Triage-RCS-patched.json  (gitignored — contains real credential names)
#
# Usage: .\patch-credentials.ps1
# Run from the lumen-n8n directory after filling in N8N_CRED_NAME_* and GCHAT_WEBHOOK_* values.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$propsFile  = Join-Path $PSScriptRoot "lumen-triage.properties"
$templateFile = Join-Path $PSScriptRoot "Lumen-Triage-RCS.json"
$outputFile = Join-Path $PSScriptRoot "Lumen-Triage-RCS-patched.json"

# --- Load properties -----------------------------------------------------------
$props = @{}
Get-Content $propsFile | ForEach-Object {
    if ($_ -match '^([^#=\s][^=]*)=(.*)$') {
        $props[$Matches[1].Trim()] = $Matches[2].Trim()
    }
}

function Get-Prop($key) { if ($props.ContainsKey($key)) { $props[$key] } else { "" } }

$dtLegacy    = Get-Prop 'N8N_CRED_NAME_DYNATRACE_LEGACY'
$dtPlatform  = Get-Prop 'N8N_CRED_NAME_DYNATRACE_PLATFORM'
$pdName      = Get-Prop 'N8N_CRED_NAME_PAGERDUTY'
$googleName  = Get-Prop 'N8N_CRED_NAME_GOOGLE_OAUTH2'
$openaiName  = Get-Prop 'N8N_CRED_NAME_FUELIX_OPENAI'
$vectorName  = Get-Prop 'N8N_CRED_NAME_FUELIX_VECTOR'
$irisName    = Get-Prop 'N8N_CRED_NAME_IRIS'
$gchatTriage   = Get-Prop 'GCHAT_WEBHOOK_TRIAGE'
$gchatError    = Get-Prop 'GCHAT_WEBHOOK_ERROR'
$pdWebhookPath = Get-Prop 'N8N_PAGERDUTY_WEBHOOK_PATH'
$wfName        = Get-Prop 'N8N_WORKFLOW_NAME'
$bqProjectId   = Get-Prop 'YOUR_BQ_PROJECT_ID'

Write-Host "Reading template : $templateFile"
Write-Host "Writing output   : $outputFile"
Write-Host ""
Write-Host "Credential names:"
Write-Host "  DYNATRACE_LEGACY   = '$dtLegacy'"
Write-Host "  DYNATRACE_PLATFORM = '$dtPlatform'"
Write-Host "  PAGERDUTY          = '$pdName'"
Write-Host "  GOOGLE_OAUTH2      = '$googleName'"
Write-Host "  FUELIX_OPENAI      = '$openaiName'"
Write-Host "  FUELIX_VECTOR      = '$vectorName'"
Write-Host "  IRIS               = '$irisName'"
Write-Host ""
Write-Host "Google Chat webhooks:"
Write-Host "  GCHAT_WEBHOOK_TRIAGE        = $(if ($gchatTriage)   { '(set)' } else { '(not set — placeholder kept)' })"
Write-Host "  GCHAT_WEBHOOK_ERROR         = $(if ($gchatError)    { '(set)' } else { '(not set — placeholder kept)' })"
Write-Host "  N8N_PAGERDUTY_WEBHOOK_PATH  = $(if ($pdWebhookPath) { $pdWebhookPath } else { '(not set — placeholder kept)' })"
Write-Host "  N8N_WORKFLOW_NAME           = $(if ($wfName) { $wfName } else { '(not set — placeholder kept)' })"
Write-Host "  YOUR_BQ_PROJECT_ID          = $(if ($bqProjectId) { $bqProjectId } else { '(not set — placeholder kept)' })"
Write-Host ""

# --- Helper: build credential object ------------------------------------------
function New-Cred($type, $name) {
    $obj = [PSCustomObject]@{}
    $obj | Add-Member -MemberType NoteProperty -Name $type -Value ([PSCustomObject]@{
        id   = "placeholder"
        name = $name
    })
    return $obj
}

# --- Load template (read-only source) -----------------------------------------
$raw = Get-Content $templateFile -Raw

# Raw string substitutions (applied before JSON parsing for efficiency)
$rawPatched = 0
if ($bqProjectId -and $raw.Contains('YOUR_BQ_PROJECT_ID')) {
    $occurrences = ([regex]::Matches($raw, 'YOUR_BQ_PROJECT_ID')).Count
    $raw = $raw.Replace('YOUR_BQ_PROJECT_ID', $bqProjectId)
    Write-Host "  [bq-project-id] $occurrences occurrence(s) → '$bqProjectId'"
    $rawPatched += $occurrences
}

$wf = $raw | ConvertFrom-Json -Depth 100

$patched = $rawPatched

# Workflow name substitution
if ($wf.name -eq 'N8N_WORKFLOW_NAME_PLACEHOLDER' -and $wfName) {
    $wf.name = $wfName
    Write-Host "  [workflow-name] → '$wfName'"
    $patched++
}

foreach ($node in $wf.nodes) {

    # PagerDuty Webhook trigger — path substitution
    if ($node.type -eq 'n8n-nodes-base.webhook' -and $node.parameters.path -eq 'N8N_PAGERDUTY_WEBHOOK_PATH_PLACEHOLDER' -and $pdWebhookPath) {
        $node.parameters.path = $pdWebhookPath
        Write-Host "  [webhook-path] $($node.name) → '$pdWebhookPath'"
        $patched++
    }

    # HTTP Request nodes
    if ($node.type -eq 'n8n-nodes-base.httpRequest') {
        $auth = if ($node.parameters.PSObject.Properties['authentication']) { [string]$node.parameters.authentication } else { "" }
        $url  = [string]$node.parameters.url

        # Google Chat webhook URL substitution
        if ($url -eq 'GCHAT_WEBHOOK_TRIAGE_PLACEHOLDER' -and $gchatTriage) {
            $node.parameters.url = $gchatTriage
            Write-Host "  [gchat-triage] $($node.name) → URL set"
            $patched++
        }
        elseif ($url -eq 'GCHAT_WEBHOOK_ERROR_PLACEHOLDER' -and $gchatError) {
            $node.parameters.url = $gchatError
            Write-Host "  [gchat-error] $($node.name) → URL set"
            $patched++
        }

        # Credential wiring
        if ($auth -eq 'predefinedCredentialType') {
            $ncType = [string]$node.parameters.nodeCredentialType
            $credName = switch ($ncType) {
                'dynatraceApi'    { $dtLegacy }
                'googleOAuth2Api' { $googleName }
                'openAiApi'       { $openaiName }
                default           { "" }
            }
            if ($credName) {
                $node | Add-Member -MemberType NoteProperty -Name credentials -Value (New-Cred $ncType $credName) -Force
                Write-Host "  [predefined/$ncType] $($node.name) → '$credName'"
                $patched++
            }
        }
        elseif ($auth -eq 'genericCredentialType') {
            $credType = if ($url -match 'apps\.dynatrace\.com|vectors\.fuelix\.ai') { 'httpBearerAuth' } else { 'httpHeaderAuth' }
            $credName = if     ($url -match 'apps\.dynatrace\.com')  { $dtPlatform }
                        elseif ($url -match 'api\.pagerduty\.com')   { $pdName }
                        elseif ($url -match 'vectors\.fuelix\.ai')   { $vectorName }
                        elseif ($url -match 'iris\.telus\.com')      { $irisName }
                        else                                          { "" }

            if ($credName) {
                $node | Add-Member -MemberType NoteProperty -Name credentials -Value (New-Cred $credType $credName) -Force
                Write-Host "  [$credType] $($node.name) → '$credName'"
                $patched++
            }
        }
    }

    # LangChain OpenAI chat model nodes
    elseif ($node.type -eq '@n8n/n8n-nodes-langchain.lmChatOpenAi') {
        if ($openaiName) {
            $node | Add-Member -MemberType NoteProperty -Name credentials -Value (New-Cred 'openAiApi' $openaiName) -Force
            Write-Host "  [openAiApi/langchain] $($node.name) → '$openaiName'"
            $patched++
        }
    }
}

Write-Host ""
Write-Host "$patched substitution(s) applied."

# --- Write output (never overwrites template) ----------------------------------
$wf | ConvertTo-Json -Depth 100 -Compress | Set-Content $outputFile -Encoding UTF8
Write-Host "Output written : $outputFile"
Write-Host ""
Write-Host "Import $outputFile into n8n."
Write-Host "The template $templateFile is unchanged."
