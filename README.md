# Real‑Time Metrics — Observability Demo Voting App on Kind

A comprehensive guide for setting up a **Kubernetes cluster using Kind** on Windows (or AWS EC2), deploying a **containerized voting application**, and integrating **Prometheus + Grafana** for observability.

---

## Overview

This guide covers:
- Launch on Local machine / AWS EC2 instance.
- Install Docker Desktop.
- Install Kind, kubectl, and Helm (with proper PATH setup).
- Create and verify a Kubernetes cluster.
- Build and load application images.
- Deploy the voting app with Redis, Postgres, and worker services.
- Set up the Kubernetes Dashboard.
- Integrate Prometheus + Grafana for real‑time observability.
- Perform load testing with Apache Benchmark.
- Cleanup instructions.

---

## 🔄 Step‑by‑Step Flow (Application Real‑Time Observability Stack)

- **Docker** → Package applications into containers. Each service (Prometheus, Grafana, etc.) runs as a container.  
- **Kubernetes** → Orchestrates containers across nodes. Ensures scaling, self‑healing, and service discovery.  
- **Helm Charts** → Simplifies deployment of complex apps (Prometheus + Grafana). Provides reusable templates.  
- **Prometheus** → Collects metrics from Kubernetes pods/nodes. Stores time‑series data (CPU, memory, network, custom app metrics).  
- **Grafana** → Connects to Prometheus as a data source. Visualizes metrics in real‑time dashboards. Alerts can be configured for anomalies.  

---

## 🏗️ Architecture

<img width="800" height="533" alt="image" src="https://github.com/user-attachments/assets/08a94108-f5da-43ac-b296-070d687ec9b9" />

<img width="950" height="456" alt="image" src="https://github.com/user-attachments/assets/aef6a5f3-7262-4d06-9108-57f4df25e345" />

## Query for testing: sum(rate(container_network_receive_bytes_total{namespace="default"}[2m])) by (pod)

Prometheous Dashboard
<img width="956" height="457" alt="image" src="https://github.com/user-attachments/assets/0af3b903-de1c-4083-9b9e-8ba0b2bf32c1" />

<img width="956" height="484" alt="image" src="https://github.com/user-attachments/assets/3c6089f0-d162-4105-83d3-5e85c7ac4647" />

===============================================
increase load:
apiVersion: v1
kind: Pod
metadata:
  name: loadtest
spec:
  containers:
  - name: hey
    image: williamyeh/hey
    command: ["hey"]
    args: ["-n", "10000", "-c", "100", "http://vote.default.svc.cluster.local:80"]
  restartPolicy: Never

kubectl apply -f loadtest.yaml
===============================================

Flow:
Docker → Kind cluster runs inside Docker (demo-control-plane container).

Kubernetes →  the cluster is healthy (kubectl get nodes shows demo-control-plane).

Helm chart →  installed kube-prometheus-stack into the monitoring namespace.

Prometheus →  port‑forwarded svc/prometheus-kube-prometheus-prometheus to localhost:9090 and are now running queries successfully.

Grafana Dashboard
<img width="951" height="476" alt="image" src="https://github.com/user-attachments/assets/e8898876-ca65-445b-a6c5-80f4459c453c" />

---

## ⚙️ Step‑by‑Step Setup

### 1️⃣ Install Docker
Download Docker Desktop for Windows from [Docker official site](https://www.docker.com/products/docker-desktop).

Verify installation:
```powershell
docker --version
2️⃣ Install Kind (Kubernetes in Docker)
Download Kind binary:

powershell
curl.exe -Lo kind.exe https://kind.sigs.k8s.io/dl/v0.23.0/kind-windows-amd64
Move to PATH:

powershell
move kind.exe C:\Windows\System32\
Verify:

powershell
kind --version
Create cluster:

powershell
kind create cluster --name demo
3️⃣ Install kubectl
Download kubectl binary:

powershell
curl.exe -LO "https://dl.k8s.io/release/v1.30.0/bin/windows/amd64/kubectl.exe"
Move to PATH:

powershell
move kubectl.exe C:\Windows\System32\
Verify:

powershell
kubectl version --client
4️⃣ Verify Cluster
powershell
kubectl cluster-info
kubectl get nodes
5️⃣ Build Application Images
powershell
docker build -t vote ./vote
docker build -t result ./result
docker build -t worker ./worker
docker images
6️⃣ Load Images into Kind
powershell
kind load docker-image vote:latest --name demo
kind load docker-image result:latest --name demo
kind load docker-image worker:latest --name demo
7️⃣ Deploy Kubernetes Manifests
powershell
kubectl apply -f k8s-specifications/
kubectl get pods
kubectl get svc
8️⃣ Access Applications
Vote App

powershell
kubectl port-forward service/vote 5000:5000
→ http://localhost:5000

Result App

powershell
kubectl port-forward service/result 5001:5001
→ http://localhost:5001

📊 Observability Setup
🔹 Install Helm
Download Helm:

powershell
curl.exe -LO https://get.helm.sh/helm-v3.15.4-windows-amd64.zip
Extract:

powershell
Expand-Archive helm-v3.15.4-windows-amd64.zip -DestinationPath .
Move to PATH:

powershell
move .\windows-amd64\helm.exe C:\Windows\System32\
Verify:

powershell
helm version
🔹 Install Prometheus & Grafana
powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus prometheus-community/kube-prometheus-stack
🔹 Access Grafana
powershell
kubectl port-forward service/kube-prometheus-grafana 3000:80
→ http://localhost:3000

Username: admin  
Password:

powershell
kubectl get secret kube-prometheus-grafana -o jsonpath="{.data.admin-password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
🔄 Updating & Rollout
After code changes:

powershell
docker build -t vote ./vote
kind load docker-image vote:latest --name demo
kubectl rollout restart deployment vote
⚡ Load Testing
Install Apache Benchmark (ab) via Apache HTTPD distribution or package manager.

Run benchmark:

powershell
ab -n 1000 -c 50 http://localhost:5000/
📊 Observability
<img width="953" height="475" alt="image" src="https://github.com/user-attachments/assets/302458f6-bf39-4ce7-a031-8aeceb1218b7" />

A front‑end web app in Python (/vote) which lets you vote between two options

A Redis which collects new votes

A .NET worker (/worker/) which consumes votes and stores them in…

A Postgres database backed by a Docker volume

A Node.js web app (/result) which shows the results of the voting in real time


After configuration How to start:
how to start and access the applications after configuration. It matches exactly the flow you followed — build, load, deploy, and then port‑forward to localhost.

markdown
# ▶️ Starting the Applications After Configuration

Once Docker, Kind, Kubernetes, Prometheus, and Grafana are installed and configured, follow these steps to start and access the applications locally.

---

## 1️⃣ Build Application Images
From the project root:
```powershell
docker build -t vote ./vote
docker build -t result ./result
docker build -t worker ./worker
2️⃣ Load Images into Kind
powershell
kind load docker-image vote:latest --name demo
kind load docker-image result:latest --name demo
kind load docker-image worker:latest --name demo
3️⃣ Deploy Kubernetes Manifests
powershell
kubectl apply -f k8s-specifications/
kubectl get pods
kubectl get svc
Confirm pods are running:

vote

result

worker

redis

db

4️⃣ Access Applications (Port‑Forward)
Since NodePort is not directly accessible in Kind, use port‑forwarding:

Vote App

powershell
kubectl port-forward service/vote 5000:5000
Access → http://localhost:5000

Result App

powershell
kubectl port-forward service/result 5001:5001
Access → http://localhost:5001

5️⃣ Access Observability Tools
Grafana

powershell
kubectl port-forward service/kube-prometheus-grafana 3000:80
Access → http://localhost:3000
Login: admin / password from secret:

powershell
kubectl get secret kube-prometheus-grafana -o jsonpath="{.data.admin-password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
Prometheus

powershell
kubectl port-forward service/kube-prometheus-kube-prome-prometheus 9090:9090
Access → http://localhost:9090




