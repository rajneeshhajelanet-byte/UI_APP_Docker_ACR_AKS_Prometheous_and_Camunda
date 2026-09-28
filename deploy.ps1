$ErrorActionPreference = "Continue"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Observability Demo - Azure Container Apps Deploy " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Configuration parameters
$RESOURCE_GROUP = "rg-observability-demo"
$LOCATION = "eastus"
$REGISTRY_NAME = "obsdemoacr01"
$ENV_NAME = "observability-demo-env"
$VNET_NAME = "vnet-observability-demo"
$SUBNET_NAME = "infra-subnet"
$TAG = "{0:yyyyMMddHHmmss}" -f (Get-Date)

# No Docker is available on this machine. Images are built server-side in
# Azure via `az acr build` instead of `docker build` + `docker push`.
# vote/ has no source checked in (only a pre-built vote.tar) and camunda/
# and the Prometheus+Grafana stack are out of scope for this pass -- see
# README notes printed at the end of this script.

# ------------------------------------------------------------------
# STEP 1: Azure Authentication Check
# ------------------------------------------------------------------
Write-Host "`n[Step 1/5] Checking Azure login status..." -ForegroundColor Yellow
$azAccount = az account show --output json 2>$null
if (-not $azAccount) {
    Write-Host "Not authenticated. Initiating Azure login..." -ForegroundColor Yellow
    az login
} else {
    Write-Host "Authenticated successfully." -ForegroundColor Green
}

# ------------------------------------------------------------------
# STEP 2: Ensure Resource Group, Registry, & ACA Environment Exist
# ------------------------------------------------------------------
Write-Host "`n[Step 2/5] Ensuring Resource Group, Registry, and ACA Environment exist..." -ForegroundColor Yellow

az group create --name $RESOURCE_GROUP --location $LOCATION --output none
Write-Host "Resource Group '$RESOURCE_GROUP' is ready." -ForegroundColor Green

$acrExists = az acr show --name $REGISTRY_NAME --output json 2>$null
if (-not $acrExists) {
    az acr create --resource-group $RESOURCE_GROUP --name $REGISTRY_NAME --sku Basic --admin-enabled true --output none
    Write-Host "Azure Container Registry '$REGISTRY_NAME' created." -ForegroundColor Green
} else {
    Write-Host "Azure Container Registry '$REGISTRY_NAME' already exists." -ForegroundColor Green
}

# A custom VNET is required so redis can get real external TCP ingress
# (Container Apps refuses external TCP on the default consumption
# environment -- see ContainerAppTcpRequiresVnet).
$vnetExists = az network vnet show --resource-group $RESOURCE_GROUP --name $VNET_NAME --output json 2>$null
if (-not $vnetExists) {
    az network vnet create `
      --resource-group $RESOURCE_GROUP `
      --name $VNET_NAME `
      --location $LOCATION `
      --address-prefix 10.10.0.0/16 `
      --subnet-name $SUBNET_NAME `
      --subnet-prefix 10.10.0.0/23 `
      --output none
    Write-Host "VNet '$VNET_NAME' created." -ForegroundColor Green
} else {
    Write-Host "VNet '$VNET_NAME' already exists." -ForegroundColor Green
}
az network vnet subnet update `
  --resource-group $RESOURCE_GROUP `
  --vnet-name $VNET_NAME `
  --name $SUBNET_NAME `
  --delegations Microsoft.App/environments `
  --output none
$SUBNET_ID = az network vnet subnet show --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --name $SUBNET_NAME --query id -o tsv

$envExists = az containerapp env show --name $ENV_NAME --resource-group $RESOURCE_GROUP --output json 2>$null
if (-not $envExists) {
    az containerapp env create `
      --name $ENV_NAME `
      --resource-group $RESOURCE_GROUP `
      --location $LOCATION `
      --infrastructure-subnet-resource-id $SUBNET_ID `
      --output none
    Write-Host "Container App Environment '$ENV_NAME' created." -ForegroundColor Green
} else {
    Write-Host "Container App Environment '$ENV_NAME' already exists." -ForegroundColor Green
}

# ------------------------------------------------------------------
# STEP 3: Remote Cloud Docker Builds (result, worker)
# ------------------------------------------------------------------
Write-Host "`n[Step 3/5] Building result and worker images in Azure Cloud..." -ForegroundColor Yellow

az acr build --registry $REGISTRY_NAME --image "result:$TAG" --image "result:latest" ./result --no-logs
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[ERROR] result image build failed. Halting pipeline execution." -ForegroundColor Red
    exit 1
}
Write-Host "result image built." -ForegroundColor Green

az acr build --registry $REGISTRY_NAME --image "worker:$TAG" --image "worker:latest" ./worker --no-logs
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[ERROR] worker image build failed. Halting pipeline execution." -ForegroundColor Red
    exit 1
}
Write-Host "worker image built." -ForegroundColor Green

$REGISTRY_SERVER = "$REGISTRY_NAME.azurecr.io"
$ACR_USER = az acr credential show --name $REGISTRY_NAME --query "username" -o tsv
$ACR_PASS = az acr credential show --name $REGISTRY_NAME --query "passwords[0].value" -o tsv

# ------------------------------------------------------------------
# STEP 4: Backing services - db (Postgres) and redis
# Named "db" and "redis" on purpose: worker/Program.cs and
# result/server.js both default to those hostnames, so no extra
# connection env vars are needed for result, and only one (SSL
# override) is needed for worker.
# ------------------------------------------------------------------
Write-Host "`n[Step 4/5] Deploying backing services (db, redis)..." -ForegroundColor Yellow

$dbExists = az containerapp show --name db --resource-group $RESOURCE_GROUP --output json 2>$null
if (-not $dbExists) {
    az containerapp create `
      --name db `
      --resource-group $RESOURCE_GROUP `
      --environment $ENV_NAME `
      --image "postgres:15-alpine" `
      --target-port 5432 `
      --ingress internal `
      --transport tcp `
      --min-replicas 1 --max-replicas 1 `
      --cpu 0.5 --memory 1.0Gi `
      --env-vars "POSTGRES_PASSWORD=postgres" "POSTGRES_DB=postgres" `
      --output none
    Write-Host "Container App 'db' created." -ForegroundColor Green
} else {
    Write-Host "Container App 'db' already exists. Leaving data volume undisturbed (no update)." -ForegroundColor Green
}

$redisExists = az containerapp show --name redis --resource-group $RESOURCE_GROUP --output json 2>$null
if (-not $redisExists) {
    az containerapp create `
      --name redis `
      --resource-group $RESOURCE_GROUP `
      --environment $ENV_NAME `
      --image "redis:7-alpine" `
      --target-port 6379 `
      --exposed-port 6379 `
      --ingress external `
      --transport tcp `
      --min-replicas 1 --max-replicas 1 `
      --cpu 0.25 --memory 0.5Gi `
      --output none
    Write-Host "Container App 'redis' created." -ForegroundColor Green
} else {
    Write-Host "Container App 'redis' already exists." -ForegroundColor Green
}

# ------------------------------------------------------------------
# STEP 5: Application services - worker and result
# ------------------------------------------------------------------
Write-Host "`n[Step 5/5] Provisioning/Updating worker and result Container Apps..." -ForegroundColor Yellow

# worker forces "Ssl Mode=Require" whenever it falls back to individual
# PGHOST/PGUSER/... vars, but the plain postgres:15-alpine image doesn't
# speak SSL. DATABASE_URL bypasses that fallback and disables SSL explicitly.
$workerEnvVars = @(
    "DATABASE_URL=Host=db;Username=postgres;Password=postgres;Database=postgres;Ssl Mode=Disable"
)

$workerExists = az containerapp show --name worker --resource-group $RESOURCE_GROUP --output json 2>$null
if (-not $workerExists) {
    az containerapp create `
      --name worker `
      --resource-group $RESOURCE_GROUP `
      --environment $ENV_NAME `
      --image "$REGISTRY_SERVER/worker:$TAG" `
      --registry-server $REGISTRY_SERVER `
      --registry-username $ACR_USER `
      --registry-password $ACR_PASS `
      --min-replicas 1 --max-replicas 1 `
      --cpu 0.5 --memory 1.0Gi `
      --env-vars $workerEnvVars `
      --output none
    Write-Host "Container App 'worker' created." -ForegroundColor Green
} else {
    az containerapp update `
      --name worker `
      --resource-group $RESOURCE_GROUP `
      --image "$REGISTRY_SERVER/worker:$TAG" `
      --set-env-vars $workerEnvVars `
      --output none
    Write-Host "Container App 'worker' updated to new revision." -ForegroundColor Green
}

$resultExists = az containerapp show --name result --resource-group $RESOURCE_GROUP --output json 2>$null
if (-not $resultExists) {
    az containerapp create `
      --name result `
      --resource-group $RESOURCE_GROUP `
      --environment $ENV_NAME `
      --image "$REGISTRY_SERVER/result:$TAG" `
      --registry-server $REGISTRY_SERVER `
      --registry-username $ACR_USER `
      --registry-password $ACR_PASS `
      --target-port 80 `
      --ingress external `
      --cpu 0.5 --memory 1.0Gi `
      --min-replicas 1 --max-replicas 1 `
      --output none
    Write-Host "Container App 'result' created." -ForegroundColor Green
} else {
    az containerapp update `
      --name result `
      --resource-group $RESOURCE_GROUP `
      --image "$REGISTRY_SERVER/result:$TAG" `
      --output none
    Write-Host "Container App 'result' updated to new revision." -ForegroundColor Green
}

# ------------------------------------------------------------------
# Access info
# ------------------------------------------------------------------
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " Deployment complete " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$resultFqdn = az containerapp show --name result --resource-group $RESOURCE_GROUP --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$redisFqdn = az containerapp show --name redis --resource-group $RESOURCE_GROUP --query "properties.configuration.ingress.fqdn" -o tsv 2>$null

Write-Host "`nresult app:  https://$resultFqdn"
Write-Host "redis (for your local vote app): ${redisFqdn}:6379"
Write-Host "`nTo run vote locally against this stack, point its Redis connection at"
Write-Host "'$redisFqdn' port 6379 instead of the default 'redis' hostname."
Write-Host "`nRedis has no auth/TLS on this open TCP endpoint -- fine for a short-lived"
Write-Host "demo, but tear it down (or add 'requirepass') if it'll sit exposed."
Write-Host "`nNot deployed in this pass: Camunda (camunda/Dockerfile references a"
Write-Host "missing processes/ folder) and Prometheus/Grafana (k8s-specifications/"
Write-Host "is empty). Revisit once that source is available."
