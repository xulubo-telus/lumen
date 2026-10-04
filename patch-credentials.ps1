# patch-credentials.ps1
# Reads credential names from lumen-triage.properties and wires them into
# Lumen-Triage-ccs-ratingprofile.json so nodes don't show empty dropdowns after import.
#
# Usage: .\patch-credentials.ps1
# Run from the lumen-n8n directory after filling in N8N_CRED_NAME_* values.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$propsFile = Join-Path $PSScriptRoot "lumen-triage.properties"
$wfFile    = Join-Path $PSScriptRoot "Lumen-Triage-RCS.json"

# --- Load properties -----------------------------------------------------------
$props = @{}
Get-Content $propsFile | ForEach-Object {
    if ($_ -match '^([^#=\s][^=]*)=(.*)$') {
        $props[$Matches[1].Trim()] = $Matches[2].Trim()
    }
}

function Get-Prop($key) { if ($props.ContainsKey($key)) { $props[$key] } else { "" } }

$dtLegacy   = Get-Prop 'N8N_CRED_NAME_DYNATRACE_LEGACY'
$dtPlatform = Get-Prop 'N8N_CRED_NAME_DYNATRACE_PLATFORM'
$pdName     = Get-Prop 'N8N_CRED_NAME_PAGERDUTY'
$googleName = Get-Prop 'N8N_CRED_NAME_GOOGLE_OAUTH2'
$openaiName = Get-Prop 'N8N_CRED_NAME_FUELIX_OPENAI'
$vectorName = Get-Prop 'N8N_CRED_NAME_FUELIX_VECTOR'
$slackName  = Get-Prop 'N8N_CRED_NAME_SLACK'
$irisName   = Get-Prop 'N8N_CRED_NAME_IRIS'

Write-Host "Credential names read from properties:"
Write-Host "  DYNATRACE_LEGACY   = '$dtLegacy'"
Write-Host "  DYNATRACE_PLATFORM = '$dtPlatform'"
Write-Host "  PAGERDUTY          = '$pdName'"
Write-Host "  GOOGLE_OAUTH2      = '$googleName'"
Write-Host "  FUELIX_OPENAI      = '$openaiName'"
Write-Host "  FUELIX_VECTOR      = '$vectorName'"
Write-Host "  SLACK              = '$slackName'"
Write-Host "  IRIS               = '$irisName'"
Write-Host ""

# --- Helper: build credential object ------------------------------------------
function New-Cred($type, $name) {
    # id uses a placeholder; n8n resolves by name on import
    $obj = [PSCustomObject]@{}
    $obj | Add-Member -MemberType NoteProperty -Name $type -Value ([PSCustomObject]@{
        id   = "placeholder"
        name = $name
    })
    return $obj
}

# --- Load workflow -------------------------------------------------------------
$raw = Get-Content $wfFile -Raw
$wf  = $raw | ConvertFrom-Json -Depth 100

$patched = 0

foreach ($node in $wf.nodes) {

    # HTTP Request nodes
    if ($node.type -eq 'n8n-nodes-base.httpRequest') {
        $auth = $node.parameters.authentication
        $url  = [string]$node.parameters.url

        if ($auth -eq 'predefinedCredentialType') {
            $ncType = [string]$node.parameters.nodeCredentialType
            $credName = switch ($ncType) {
                'dynatraceApi'   { $dtLegacy }
                'googleOAuth2Api' { $googleName }
                'openAiApi'      { $openaiName }
                default          { "" }
            }
            if ($credName) {
                $node | Add-Member -MemberType NoteProperty -Name credentials -Value (New-Cred $ncType $credName) -Force
                Write-Host "  [predefined/$ncType] $($node.name) → '$credName'"
                $patched++
            }
        }

        elseif ($auth -eq 'genericCredentialType') {
            # Bearer-token services use httpBearerAuth; header-based services use httpHeaderAuth
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

    # Slack nodes
    elseif ($node.type -eq 'n8n-nodes-base.slack') {
        if ($slackName) {
            $node | Add-Member -MemberType NoteProperty -Name credentials -Value (New-Cred 'slackApi' $slackName) -Force
            Write-Host "  [slackApi] $($node.name) → '$slackName'"
            $patched++
        }
    }
}

Write-Host ""
Write-Host "$patched node(s) patched."

# --- Save ---------------------------------------------------------------------
$wf | ConvertTo-Json -Depth 100 -Compress | Set-Content $wfFile -Encoding UTF8
Write-Host "Saved: $wfFile"
Write-Host ""
Write-Host "Next: import the updated JSON into n8n."
Write-Host "If n8n still shows empty credential dropdowns, open each node and"
Write-Host "select the credential manually — the name must match exactly."
