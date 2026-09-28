param(
    [string]$App = "redis",
    [string]$Namespace = "default",
    [int]$TailLines = 50
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 has no -SkipCertificateCheck (that's PS7+ only) -- the
# AKS API server uses a cluster-CA cert, so bypass validation the PS5.1 way.
if (-not ("TrustAllCertsPolicy" -as [type])) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$apiServer = "https://aks-observ-rg-observability-cddfd6-dilvjtxz.hcp.eastus.azmk8s.io"
$tokenFile = Join-Path $PSScriptRoot "local-dev\aks_log_token.txt"

if (-not (Test-Path $tokenFile)) {
    Write-Host "Token file not found: $tokenFile" -ForegroundColor Red
    Write-Host "Regenerate it with:" -ForegroundColor Yellow
    Write-Host "  az aks command invoke -g rg-observability-demo -n aks-observability-demo --command `"kubectl create token log-reader -n default --duration=24h`"" -ForegroundColor Yellow
    exit 1
}

$token = (Get-Content $tokenFile -Raw).Trim()
$headers = @{ Authorization = "Bearer $token" }

# The token is scoped to get/list pods and pods/log only (RBAC role log-reader-role).
# It expires 24h after being minted -- a 401/403 here usually means it's stale.

Write-Host "Resolving current pod for app=$App in namespace $Namespace..." -ForegroundColor Cyan
$podsUrl = "$apiServer/api/v1/namespaces/$Namespace/pods?labelSelector=app%3D$App"

try {
    $podsResp = Invoke-RestMethod -Uri $podsUrl -Headers $headers
} catch {
    Write-Host "Failed to list pods: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "If this is a 401/403, the token has likely expired -- regenerate it (see above)." -ForegroundColor Yellow
    exit 1
}

if (-not $podsResp.items -or $podsResp.items.Count -eq 0) {
    Write-Host "No running pods found with label app=$App in namespace $Namespace." -ForegroundColor Red
    exit 1
}

$podName = $podsResp.items[0].metadata.name
Write-Host "Pod: $podName" -ForegroundColor Green

$logsUrl = "$apiServer/api/v1/namespaces/$Namespace/pods/$podName/log?tailLines=$TailLines"

Write-Host "--- logs ---" -ForegroundColor Cyan
$response = Invoke-WebRequest -Uri $logsUrl -Headers $headers -UseBasicParsing
Write-Host $response.Content
