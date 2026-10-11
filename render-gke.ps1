# render-gke.ps1
# Renders Lumen-GKE-Debug.json → Lumen-GKE-Debug-patched.json
# Delegates to render.ps1 with -Template Lumen-GKE-Debug.json.
#
# Usage:
#   .\render-gke.ps1
#   .\render-gke.ps1 lumen-triage-common.properties, lumen-triage-np.properties

param(
    [string[]]$PropsFiles = @("lumen-triage-common.properties", "lumen-triage-pr.properties")
)

& "$PSScriptRoot\render.ps1" -Template "Lumen-GKE-Debug.json" -PropsFiles $PropsFiles
