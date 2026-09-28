Write-Host "=== Starting Demo Cluster Stack ==="

function Ensure-Cluster {
    if (-not (kind get clusters | Select-String "demo")) {
        Write-Host "Creating kind cluster 'demo'..."
        kind create cluster --name demo
    } else {
        Write-Host "Cluster 'demo' already exists."
    }

    kind export kubeconfig --name demo
    kubectl config use-context kind-demo | Out-Null
}

function Ensure-Resource {
    param(
        [string]$ResourceType,
        [string]$ResourceName,
        [string]$ManifestPath
    )

    if (-not (kubectl get $ResourceType $ResourceName -n default 2>$null)) {
        Write-Host "Creating missing $ResourceType/$ResourceName from $ManifestPath"
        kubectl apply -f $ManifestPath | Write-Host
    } else {
        Write-Host "$ResourceType/$ResourceName already exists. Skipping create."
    }
}

function Ensure-Service {
    param(
        [string]$ServiceName,
        [string]$ManifestPath
    )

    if (-not (kubectl get svc $ServiceName -n default 2>$null)) {
        Write-Host "Creating missing service '$ServiceName' from $ManifestPath"
    } else {
        Write-Host "Service '$ServiceName' already exists. Applying manifest to reconcile any changes."
    }

    kubectl apply -f $ManifestPath | Write-Host
}

function Ensure-Deployment {
    param(
        [string]$DeploymentName,
        [string]$ManifestPath
    )

    if (-not (kubectl get deployment $DeploymentName -n default 2>$null)) {
        Write-Host "Creating missing deployment '$DeploymentName' from $ManifestPath"
    } else {
        Write-Host "Deployment '$DeploymentName' already exists. Applying manifest to reconcile any changes."
    }

    kubectl apply -f $ManifestPath | Write-Host
}

function Wait-DeploymentReady {
    param(
        [string]$DeploymentName
    )

    if (kubectl get deployment $DeploymentName -n default 2>$null) {
        Write-Host "Waiting for deployment/$DeploymentName to become available..."
        kubectl wait --for=condition=available --timeout=300s deployment/$DeploymentName -n default
    } else {
        Write-Host "Deployment/$DeploymentName does not exist; skipping wait."
    }
}

function Ensure-ServiceNodePort {
    param(
        [string]$ServiceName,
        [int]$Port,
        [int]$TargetPort,
        [int]$NodePort,
        [string]$Namespace = "default"
    )

    if (-not (kubectl get svc $ServiceName -n $Namespace 2>$null)) {
        Write-Host "Service $ServiceName does not exist in namespace $Namespace; skipping NodePort patch."
        return
    }

    $currentType = kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.spec.type}' 2>$null
    $currentNodePort = kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.spec.ports[0].nodePort}' 2>$null

    if ($currentType -ne 'NodePort' -or $currentNodePort -ne $NodePort.ToString()) {
        $patch = @{
            spec = @{
                type = 'NodePort'
                ports = @(
                    @{
                        port = $Port
                        targetPort = $TargetPort
                        nodePort = $NodePort
                    }
                )
            }
        } | ConvertTo-Json -Compress

        Write-Host "Patching service $ServiceName in namespace $Namespace to NodePort $NodePort..."
        kubectl patch svc $ServiceName -n $Namespace -p $patch | Write-Host
    } else {
        Write-Host "Service $ServiceName already has NodePort $currentNodePort."
    }
}

function Wait-LocalPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 15
    )

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Ensure-PrometheusStack {
    param(
        [string]$Namespace = "monitoring",
        [string]$ReleaseName = "prometheus"
    )

    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        Write-Host "Helm is not installed or not available in PATH; skipping Prometheus stack installation."
        return $false
    }

    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    Write-Host "Ensuring kube-prometheus-stack release '$ReleaseName' is installed in namespace '$Namespace'..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force 2>$null | Out-Null
    helm repo update 2>$null | Out-Null
    helm upgrade --install $ReleaseName prometheus-community/kube-prometheus-stack -n $Namespace --create-namespace | Write-Host

    return $true
}

function Ensure-PortForward {
    param(
        [int]$LocalPort,
        [int]$RemotePort,
        [string]$ServiceName,
        [string]$Namespace = "default"
    )

    if (-not (kubectl get svc $ServiceName -n $Namespace 2>$null)) {
        Write-Host "Service $ServiceName does not exist in namespace $Namespace; skipping port-forward."
        return $false
    }

    $portInUse = Test-NetConnection -ComputerName 127.0.0.1 -Port $LocalPort -InformationLevel Quiet
    if ($portInUse) {
        Write-Host "Local port $LocalPort is already in use, skipping port-forward."
        return $false
    }

    $portForwardArg = "{0}:{1}" -f $LocalPort, $RemotePort
    $args = @('port-forward', "svc/$ServiceName", $portForwardArg, '-n', $Namespace)
    Write-Host "Starting kubectl port-forward for svc/$ServiceName to localhost:$LocalPort..."
    $process = Start-Process -FilePath 'kubectl' -ArgumentList $args -WindowStyle Hidden -PassThru

    if (-not $process) {
        Write-Host "Failed to start kubectl port-forward process for $ServiceName."
        return $false
    }

    for ($i = 0; $i -lt 15; $i++) {
        if ($process.HasExited) {
            Write-Host "kubectl port-forward process exited unexpectedly for $ServiceName."
            return $false
        }

        if (Wait-LocalPort -Port $LocalPort -TimeoutSeconds 1) {
            Write-Host "Port-forward is active on localhost:$LocalPort."
            return $true
        }
    }

    Write-Host "Timed out waiting for port-forward to open localhost:$LocalPort."
    return $false
}

Ensure-Cluster

Write-Host "=== Building and loading vote-app image ==="
docker build -t vote-app:latest ./vote
kind load docker-image vote-app:latest --name demo

Write-Host "=== Ensuring required Kubernetes resources ==="
Ensure-Service -ServiceName camunda -ManifestPath "k8s-specifications/app/camunda-deployment.yaml"
Ensure-Deployment -DeploymentName camunda -ManifestPath "k8s-specifications/app/camunda-deployment.yaml"
Ensure-Deployment -DeploymentName vote -ManifestPath "k8s-specifications/app/vote-deployment.yaml"
Ensure-Deployment -DeploymentName result -ManifestPath "k8s-specifications/app/result-deployment.yaml"
kubectl apply -f k8s-specifications/services/vote-service.yaml | Write-Host
kubectl apply -f k8s-specifications/services/result-service.yaml | Write-Host

Write-Host "=== Waiting for deployments ==="
Wait-DeploymentReady -DeploymentName camunda
Wait-DeploymentReady -DeploymentName vote
Wait-DeploymentReady -DeploymentName result

Write-Host "=== Applying monitoring and shared resources if missing ==="
kubectl apply -f k8s-specifications/ 2>$null | Write-Host

Write-Host "=== Ensuring Prometheus stack is available locally ==="
$prometheusInstalled = Ensure-PrometheusStack -Namespace monitoring -ReleaseName monitoring

Write-Host "=== Patching NodePort services ==="
Ensure-ServiceNodePort -ServiceName camunda -Port 8080 -TargetPort 8080 -NodePort 31004 -Namespace default
Ensure-ServiceNodePort -ServiceName vote -Port 5000 -TargetPort 80 -NodePort 31002 -Namespace default
Ensure-ServiceNodePort -ServiceName result -Port 5001 -TargetPort 80 -NodePort 31001 -Namespace default

Write-Host "=== Starting local port-forwarding for monitoring services ==="
$camundaLocal8081 = Ensure-PortForward -LocalPort 8081 -RemotePort 8080 -ServiceName camunda -Namespace default
$camundaLocal8082 = Ensure-PortForward -LocalPort 8082 -RemotePort 8080 -ServiceName camunda -Namespace default
$prometheusLocal = Ensure-PortForward -LocalPort 9090 -RemotePort 9090 -ServiceName prometheus-kube-prometheus-prometheus -Namespace monitoring
$grafanaLocal = Ensure-PortForward -LocalPort 3000 -RemotePort 80 -ServiceName prometheus-grafana -Namespace monitoring

Write-Host "=== Access URLs ==="
Write-Host "Camunda Cockpit (NodePort): http://localhost:31004/camunda/app/cockpit/default/#/processes"
Write-Host "Camunda REST API (NodePort): http://localhost:31004/engine-rest/"
if ($camundaLocal8081) { Write-Host "Camunda Cockpit (local): http://localhost:8081/camunda/app/cockpit/default/#/processes" }
if ($camundaLocal8082) { Write-Host "Camunda REST API (local): http://localhost:8082/engine-rest/" }
if ($prometheusLocal) { Write-Host "Prometheus (local): http://localhost:9090/" } else { Write-Host "Prometheus local port-forward failed; run 'kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090' manually." }
if ($grafanaLocal) { Write-Host "Grafana (local): http://localhost:3000/" } else { Write-Host "Grafana local port-forward failed; run 'kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80' manually." }
Write-Host "Vote App: http://localhost:31002/"
Write-Host "Result App: http://localhost:31001/"
