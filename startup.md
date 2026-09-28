🛠️ Deployment Steps
Step 1: Build & Load Docker Image
Build the updated Flask vote application image and load it directly into your active demo Kind cluster:

PowerShell
# 1. Build the updated vote app image
docker build -t vote-app:latest ./vote

# 2. Load the image into your active "demo" Kind cluster
kind load docker-image vote-app:latest --name demo
Step 2: Deploy Kubernetes Specifications
Apply the Kubernetes manifests to deploy base infrastructure and explicitly launch the Camunda engine and vote application pods:

PowerShell
# Apply base infrastructure (Redis, PostgreSQL, Services, etc.)
kubectl apply -f k8s-specifications/

# Deploy Camunda Engine and Vote App deployments explicitly
kubectl apply -f k8s-specifications/camunda-deployment.yaml
kubectl apply -f k8s-specifications/vote-deployment.yaml

# Restart the vote deployment to load the fresh vote-app:latest image
kubectl rollout restart deployment vote

# Verify all pods are in Running status
kubectl get pods
Step 3: Set Up Port Forwarding
Expose the services locally to allow traffic routing to both the Vote Web UI and the Camunda REST engine:

PowerShell
# Forward Vote App (Port 5000)
kubectl port-forward svc/vote 5000:80

# Forward Camunda Engine (Port 8081 -> 8080)
kubectl port-forward svc/camunda 8081:8080
Step 4: Deploy BPMN Process & Run External Task Worker
Deploy the workflow process model into Camunda and execute the Python task polling worker:

PowerShell
# Deploy BPMN workflow diagram to Camunda Engine REST API
curl.exe -X POST "http://localhost:8081/engine-rest/deployment/create" `
  -F "deployment-name=vote-deployment" `
  -F "data=@.\worker-camunda\vote.bpmn"

# Start the Python task worker to process orchestration jobs
python worker-camunda/Camundaflow.py
📊 Observability & Verification
Prometheus Monitoring Query
Use the following PromQL metric query in Prometheus or Grafana to track Camunda container CPU consumption:

Code snippet
rate(container_cpu_usage_seconds_total{pod=~"camunda-.*", container="camunda"}[2m])
Live Log Streaming
Open a separate terminal to stream incoming logs and verify log tagging differentiation between direct browser traffic and worker orchestrated traffic:

PowerShell
kubectl logs -f deployment/vote
