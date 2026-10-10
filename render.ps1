# render.ps1
# Reads Lumen-Triage-external.json and one or more .properties files, substitutes
# all YOUR_* placeholders, wires credentials into every node, and writes:
#   Lumen-Triage-external-patched.json  (gitignored — contains real values)
#
# Files are loaded left-to-right; later files override earlier ones.
#
# Usage:
#   .\render.ps1                                                                          # default: common + np
#   .\render.ps1 lumen-triage-common.properties, lumen-triage-np.properties              # explicit default
#   .\render.ps1 lumen-triage-common.properties, lumen-triage.properties                 # PR environment

param(
    [string[]]$PropsFiles = @("lumen-triage-common.properties", "lumen-triage-np.properties")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$templateFile = Join-Path $PSScriptRoot "Lumen-Triage-external.json"
$outputFile   = Join-Path $PSScriptRoot "Lumen-Triage-external-patched.json"

# --- Load properties (later files override earlier ones) ----------------------
$props = @{}
foreach ($file in $PropsFiles) {
    $path = Join-Path $PSScriptRoot $file.Trim()
    if (-not (Test-Path $path)) { Write-Error "Properties file not found: $path"; exit 1 }
    Get-Content $path | ForEach-Object {
        if ($_ -match '^([^#=\s][^=]*)=(.*)$') {
            $props[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
}

function Get-Prop($key) { if ($props.ContainsKey($key)) { $props[$key] } else { "" } }

$dtTenant      = Get-Prop 'YOUR_DYNATRACE_TENANT'
$gcpProjectId  = Get-Prop 'YOUR_GCP_PROJECT_ID'
$gcpLoggingId  = Get-Prop 'YOUR_GCP_LOGGING_PROJECT_ID'
$gkeCluster    = Get-Prop 'YOUR_GKE_CLUSTER_NAME'
$namespacesRaw = Get-Prop 'YOUR_K8S_NAMESPACES'
$nsList        = if ($namespacesRaw) { $namespacesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
$appName       = Get-Prop 'YOUR_APP_NAME'
$appPrefix     = Get-Prop 'YOUR_APP_PREFIX'
$ownSvcPattern = Get-Prop 'YOUR_OWN_SERVICE_PATTERN'
$cloudsql1     = Get-Prop 'YOUR_CLOUDSQL_INSTANCE_1'
$cloudsql2     = Get-Prop 'YOUR_CLOUDSQL_INSTANCE_2'
$redisInst     = Get-Prop 'YOUR_REDIS_INSTANCE_NAME'
$rumAppId      = Get-Prop 'YOUR_RUM_APPLICATION_ID'
$bqProjectId   = Get-Prop 'YOUR_BQ_PROJECT_ID'
$bqLocation    = Get-Prop 'YOUR_BQ_LOCATION'
$org           = Get-Prop 'YOUR_ORG'
$runbookRepo   = Get-Prop 'YOUR_RUNBOOK_REPO'

$wfName        = Get-Prop 'N8N_WORKFLOW_NAME'
$pdWebhookPath = Get-Prop 'N8N_PAGERDUTY_WEBHOOK_PATH'

$dtLegacy      = Get-Prop 'N8N_CRED_NAME_DYNATRACE_LEGACY'
$dtPlatform    = Get-Prop 'N8N_CRED_NAME_DYNATRACE_PLATFORM'
$pdName        = Get-Prop 'N8N_CRED_NAME_PAGERDUTY'
$googleName    = Get-Prop 'N8N_CRED_NAME_GOOGLE_OAUTH2'
$openaiName    = Get-Prop 'N8N_CRED_NAME_FUELIX_OPENAI'
$vectorName    = Get-Prop 'N8N_CRED_NAME_FUELIX_VECTOR'
$irisName      = Get-Prop 'N8N_CRED_NAME_IRIS'

Write-Host "Template : $templateFile"
foreach ($file in $PropsFiles) { Write-Host "Props    : $(Join-Path $PSScriptRoot $file.Trim())" }
Write-Host "Output   : $outputFile"
Write-Host ""
Write-Host "Infrastructure:"
Write-Host "  YOUR_DYNATRACE_TENANT        = '$dtTenant'"
Write-Host "  YOUR_GCP_PROJECT_ID          = '$gcpProjectId'"
Write-Host "  YOUR_GCP_LOGGING_PROJECT_ID  = '$gcpLoggingId'"
Write-Host "  YOUR_GKE_CLUSTER_NAME        = '$gkeCluster'"
Write-Host "  YOUR_K8S_NAMESPACES          = $(if ($nsList.Count) { "[$($nsList -join ', ')]" } else { '(not set)' })"
Write-Host "  YOUR_APP_NAME                = '$appName'"
Write-Host "  YOUR_APP_PREFIX              = '$appPrefix'"
Write-Host "  YOUR_OWN_SERVICE_PATTERN     = '$ownSvcPattern'"
Write-Host "  YOUR_CLOUDSQL_INSTANCE_1     = '$cloudsql1'"
Write-Host "  YOUR_CLOUDSQL_INSTANCE_2     = $(if ($cloudsql2) { "'$cloudsql2'" } else { '(not set)' })"
Write-Host "  YOUR_REDIS_INSTANCE_NAME     = $(if ($redisInst) { "'$redisInst'" } else { '(not set)' })"
Write-Host "  YOUR_RUM_APPLICATION_ID      = $(if ($rumAppId)  { "'$rumAppId'"  } else { '(not set — RUM enrichment skipped)' })"
Write-Host "  YOUR_BQ_PROJECT_ID           = '$bqProjectId'"
Write-Host "  YOUR_BQ_LOCATION             = '$bqLocation'"
Write-Host "  YOUR_ORG                     = '$org'"
Write-Host "  YOUR_RUNBOOK_REPO            = '$runbookRepo'"
Write-Host ""
Write-Host "Workflow:"
Write-Host "  N8N_WORKFLOW_NAME            = '$wfName'"
Write-Host "  N8N_PAGERDUTY_WEBHOOK_PATH   = '$pdWebhookPath'"
Write-Host ""
Write-Host "Credentials:"
Write-Host "  DYNATRACE_LEGACY   = '$dtLegacy'"
Write-Host "  DYNATRACE_PLATFORM = '$dtPlatform'"
Write-Host "  PAGERDUTY          = '$pdName'"
Write-Host "  GOOGLE_OAUTH2      = '$googleName'"
Write-Host "  FUELIX_OPENAI      = '$openaiName'"
Write-Host "  FUELIX_VECTOR      = '$vectorName'"
Write-Host "  IRIS               = '$irisName'"
Write-Host ""
Write-Host "Applying substitutions..."

# --- Raw string substitutions (before JSON parse, for efficiency) -------------
$raw = Get-Content $templateFile -Raw
$rawPatched = 0

# Build the 4 namespace expansion variants from $nsList.
# Each variant is the exact bytes needed in the raw JSON file for a given encoding context.
#
#   DQL       — DQL in() list inside JSON.stringify(), so quotes are double-escaped: \\\"ns\\\"
#   GCP_OR    — Cloud Logging OR filter inside JSON string: \"ns\" OR \"ns\"
#   GCP_EACH  — GCP link builder with repeated label= prefix:  resource.labels.namespace_name=\"ns\" OR ...
#   JSARRAY   — JavaScript array fallback: [\"ns1\",\"ns2\"]
if ($nsList.Count) {
    $nsDql     = '\\\"' + ($nsList -join '\\\", \\\"')     + '\\\"'
    $nsGcpOr   = '\"'   + ($nsList -join '\" OR \"')       + '\"'
    $nsGcpEach = ($nsList | ForEach-Object { 'resource.labels.namespace_name=\"' + $_ + '\"' }) -join ' OR '
    $nsJsArray = '[\"'  + ($nsList -join '\", \"')          + '\"]'
} else {
    $nsDql = $nsGcpOr = $nsGcpEach = $nsJsArray = ""
}

# Order matters: longer/more-specific keys before any shorter key that could be
# a prefix of them (e.g. YOUR_GCP_LOGGING_PROJECT_ID before YOUR_GCP_PROJECT_ID).
$substitutions = [ordered]@{
    'YOUR_GCP_LOGGING_PROJECT_ID'    = $gcpLoggingId
    'YOUR_GCP_PROJECT_ID'            = $gcpProjectId
    'YOUR_DYNATRACE_TENANT'          = $dtTenant
    'YOUR_GKE_CLUSTER_NAME'          = $gkeCluster
    'YOUR_K8S_NAMESPACES_DQL'        = $nsDql
    'YOUR_K8S_NAMESPACES_GCP_OR'     = $nsGcpOr
    'YOUR_K8S_NAMESPACES_GCP_EACH'   = $nsGcpEach
    'YOUR_K8S_NAMESPACES_JSARRAY'    = $nsJsArray
    'YOUR_APP_NAME'                  = $appName
    'YOUR_APP_PREFIX'             = $appPrefix
    'YOUR_OWN_SERVICE_PATTERN'    = $ownSvcPattern
    'YOUR_CLOUDSQL_INSTANCE_1'    = $cloudsql1
    'YOUR_CLOUDSQL_INSTANCE_2'    = $cloudsql2
    'YOUR_REDIS_INSTANCE_NAME'    = $redisInst
    'YOUR_RUM_APPLICATION_ID'     = $rumAppId
    'YOUR_BQ_PROJECT_ID'          = $bqProjectId
    'YOUR_BQ_LOCATION'            = $bqLocation
    'YOUR_ORG'                    = $org
    'YOUR_RUNBOOK_REPO'           = $runbookRepo
}

foreach ($key in $substitutions.Keys) {
    $val = $substitutions[$key]
    if ($val -and $raw.Contains($key)) {
        $count = ([regex]::Matches($raw, [regex]::Escape($key))).Count
        $raw = $raw.Replace($key, $val)
        Write-Host "  [raw] $key ($count occurrence(s)) → '$val'"
        $rawPatched += $count
    } elseif (-not $val -and $raw.Contains($key)) {
        $count = ([regex]::Matches($raw, [regex]::Escape($key))).Count
        Write-Host "  [SKIP] $key — not set in any properties file ($count placeholder(s) left unreplaced)"
    }
}

# --- Parse JSON ---------------------------------------------------------------
$wf = $raw | ConvertFrom-Json -Depth 100
$patched = $rawPatched

# Workflow name
if ($wfName -and $wf.name -ne $wfName) {
    $wf.name = $wfName
    Write-Host "  [workflow-name] → '$wfName'"
    $patched++
}

# --- Helper: build credential object -----------------------------------------
function New-Cred($type, $name) {
    $obj = [PSCustomObject]@{}
    $obj | Add-Member -MemberType NoteProperty -Name $type -Value ([PSCustomObject]@{
        id   = "placeholder"
        name = $name
    })
    return $obj
}

# --- Node patching ------------------------------------------------------------
foreach ($node in $wf.nodes) {

    # PagerDuty webhook trigger — always overwrite path if configured
    if ($node.type -eq 'n8n-nodes-base.webhook' -and $pdWebhookPath) {
        $node.parameters.path = $pdWebhookPath
        Write-Host "  [webhook-path] $($node.name) → '$pdWebhookPath'"
        $patched++
    }

    elseif ($node.type -eq 'n8n-nodes-base.httpRequest') {
        $auth = if ($node.parameters.PSObject.Properties['authentication']) { [string]$node.parameters.authentication } else { "" }
        $url  = if ($node.parameters.PSObject.Properties['url'])            { [string]$node.parameters.url }            else { "" }

        if ($auth -eq 'predefinedCredentialType') {
            $ncType   = [string]$node.parameters.nodeCredentialType
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
            $credName = if     ($url -match 'apps\.dynatrace\.com') { $dtPlatform }
                        elseif ($url -match 'api\.pagerduty\.com')  { $pdName }
                        elseif ($url -match 'vectors\.fuelix\.ai')  { $vectorName }
                        elseif ($url -match 'iris\.telus\.com')     { $irisName }
                        else                                         { "" }
            if ($credName) {
                $node | Add-Member -MemberType NoteProperty -Name credentials -Value (New-Cred $credType $credName) -Force
                Write-Host "  [$credType] $($node.name) → '$credName'"
                $patched++
            }
        }
    }

    # LangChain OpenAI chat model (Claude Chat Model, Outcome Chat Model)
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

# --- Write output (never overwrites template) ---------------------------------
$wf | ConvertTo-Json -Depth 100 -Compress | Set-Content $outputFile -Encoding UTF8
Write-Host "Output written : $outputFile"
Write-Host ""
Write-Host "Import $outputFile into n8n."
Write-Host "The template $templateFile is unchanged."
