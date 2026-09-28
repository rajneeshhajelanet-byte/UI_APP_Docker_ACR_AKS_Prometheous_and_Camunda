$ErrorActionPreference = "Continue"

$root = $PSScriptRoot
$pidsFile = Join-Path $root "local-dev\pids.json"

if (-not (Test-Path $pidsFile)) {
    Write-Host "No $pidsFile found -- nothing to stop (or it was already cleaned up)." -ForegroundColor Yellow
    exit 0
}

$pids = Get-Content $pidsFile | ConvertFrom-Json

foreach ($name in $pids.PSObject.Properties.Name) {
    $procId = $pids.$name
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "Stopping $name (pid $procId)..." -ForegroundColor Yellow
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "$name (pid $procId) already stopped." -ForegroundColor DarkGray
    }
}

Remove-Item $pidsFile -ErrorAction SilentlyContinue
Write-Host "Done." -ForegroundColor Green
