$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Observability Demo - Local Run (no Docker/Azure) " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This starts the app stack entirely on localhost using only pip/npm" -ForegroundColor DarkGray
Write-Host "packages (no installers, no admin rights):" -ForegroundColor DarkGray
Write-Host "  - redis stub   : fakeredis (pip)             -> tcp://127.0.0.1:6379" -ForegroundColor DarkGray
Write-Host "  - postgres stub: PGlite + pglite-socket (npm) -> tcp://127.0.0.1:5432" -ForegroundColor DarkGray
Write-Host "  - dev-worker   : Python stand-in for worker/Program.cs (needs .NET SDK, not available here)" -ForegroundColor DarkGray
Write-Host "  - vote         : the reconstructed Flask app  -> http://localhost:5000" -ForegroundColor DarkGray
Write-Host "  - result       : the existing Node app        -> http://localhost:5001" -ForegroundColor DarkGray
Write-Host ""

$root = $PSScriptRoot
$localDev = Join-Path $root "local-dev"
$voteDir = Join-Path $root "vote"
$resultDir = Join-Path $root "result"
$logsDir = Join-Path $localDev "logs"
$pidsFile = Join-Path $localDev "pids.json"

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

# ------------------------------------------------------------------
# One-time setup: venvs and node_modules
# ------------------------------------------------------------------
function Ensure-Venv {
    param([string]$Dir, [string[]]$Packages)

    $venvPython = Join-Path $Dir ".venv\Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        Write-Host "Creating venv in $Dir..." -ForegroundColor Yellow
        python -m venv (Join-Path $Dir ".venv")
    }
    Write-Host "Ensuring packages in ${Dir}: $($Packages -join ', ')" -ForegroundColor Yellow
    & $venvPython -m pip install --disable-pip-version-check -q @Packages
    return $venvPython
}

function Ensure-NodeModules {
    param([string]$Dir)

    if (-not (Test-Path (Join-Path $Dir "node_modules"))) {
        Write-Host "Running npm install in $Dir..." -ForegroundColor Yellow
        Push-Location $Dir
        npm install --no-fund --no-audit | Out-Null
        Pop-Location
    }
}

$votePython = Ensure-Venv -Dir $voteDir -Packages @("flask==2.2.5", "requests==2.31.0", "redis==5.0.1", "gunicorn")
$devPython = Ensure-Venv -Dir $localDev -Packages @("fakeredis", "redis", "pg8000")
Ensure-NodeModules -Dir $localDev
Ensure-NodeModules -Dir $resultDir

# ------------------------------------------------------------------
# Launch each process, capture PIDs so stop-local.ps1 can clean up
# ------------------------------------------------------------------
function Start-Component {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [hashtable]$Env = @{}
    )

    $stdout = Join-Path $logsDir "$Name.out.log"
    $stderr = Join-Path $logsDir "$Name.err.log"

    foreach ($key in $Env.Keys) {
        [System.Environment]::SetEnvironmentVariable($key, $Env[$key], "Process")
    }

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
        -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    Write-Host "Started $Name (pid $($proc.Id)) -- logs: $stdout" -ForegroundColor Green
    return $proc.Id
}

$pids = @{}

$pids["redis_stub"] = Start-Component -Name "redis_stub" -FilePath $devPython `
    -ArgumentList @("-u", "redis_stub.py") -WorkingDirectory $localDev

$pids["pg_stub"] = Start-Component -Name "pg_stub" -FilePath "node" `
    -ArgumentList @("pg_stub.mjs") -WorkingDirectory $localDev

Write-Host "Waiting for redis/postgres stubs to come up..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

$pids["dev_worker"] = Start-Component -Name "dev_worker" -FilePath $devPython `
    -ArgumentList @("-u", "dev_worker.py") -WorkingDirectory $localDev

$pids["vote"] = Start-Component -Name "vote" -FilePath $votePython `
    -ArgumentList @("app.py") -WorkingDirectory $voteDir `
    -Env @{ REDIS_HOST = "127.0.0.1"; REDIS_PORT = "6379"; PORT = "5000" }

$pids["result"] = Start-Component -Name "result" -FilePath "node" `
    -ArgumentList @("server.js") -WorkingDirectory $resultDir `
    -Env @{ DB_HOST = "127.0.0.1"; PORT = "5001" }

$pids | ConvertTo-Json | Out-File -FilePath $pidsFile -Encoding utf8

Write-Host ""
Write-Host "=== Access URLs ===" -ForegroundColor Cyan
Write-Host "Vote:   http://localhost:5000/"
Write-Host "Result: http://localhost:5001/"
Write-Host ""
Write-Host "Note: worker/Program.cs (the real C# worker) is NOT running -- this" -ForegroundColor DarkGray
Write-Host "machine has no .NET SDK and none could be installed. dev_worker.py" -ForegroundColor DarkGray
Write-Host "stands in for it locally. Once a real .NET SDK is available, replace" -ForegroundColor DarkGray
Write-Host "it with the real worker (same Redis/Postgres endpoints)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Logs: $logsDir" -ForegroundColor DarkGray
Write-Host "To stop everything: .\stop-local.ps1" -ForegroundColor DarkGray
