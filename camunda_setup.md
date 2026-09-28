# 🗳️ Voting App Flow with Camunda

## 🚀 Prerequisites
- Kubernetes cluster ([kind](ca://s?q=kind_kubernetes_cluster) / [minikube](ca://s?q=minikube_kubernetes_cluster))
- Camunda BPM Platform running (`kubectl apply -f camunda-deployment.yaml`)
- [Camunda Modeler](ca://s?q=Camunda_Modeler_download) (downloaded and installed)
- Python 3.x for worker scripts
- Redis/Postgres backend (for vote storage)

---

## 🛠️ Starting Services

### 1. Start Kubernetes Cluster
```bash
kind create cluster --name demo
2. Deploy Camunda
bash
kubectl apply -f camunda-deployment.yaml
kubectl get pods -n default
3. Access Camunda
URL: http://localhost:31004/camunda-welcome

Login: demo / demo

🎨 Modeling the Process
Open Camunda Modeler.

Create a new BPMN diagram (Camunda 7).

Add:

Start Event

Service Task → External Task → Topic = vote-worker

Service Task → External Task → Topic = result-worker

End Event

Save as voting-process.bpmn.

Deploy Process
Click Deploy in Modeler.

REST endpoint: http://localhost:31004/engine-rest

Deployment name: voting-demo

🐍 Python Workers
Vote Worker
python
import requests, time

BASE_URL = "http://localhost:31004/engine-rest"

def fetch_and_complete():
    resp = requests.post(f"{BASE_URL}/external-task/fetchAndLock", json={
        "workerId": "vote-worker",
        "maxTasks": 1,
        "topics": [{"topicName": "vote-worker", "lockDuration": 10000}]
    })
    for task in resp.json():
        print("Processing vote task", task["id"])
        # TODO: update vote in DB/Redis
        requests.post(f"{BASE_URL}/external-task/{task['id']}/complete", json={"workerId": "vote-worker"})

while True:
    fetch_and_complete()
    time.sleep(2)
Result Worker
python
import requests, time

BASE_URL = "http://localhost:31004/engine-rest"

def fetch_and_complete_result():
    resp = requests.post(f"{BASE_URL}/external-task/fetchAndLock", json={
        "workerId": "result-worker",
        "maxTasks": 1,
        "topics": [{"topicName": "result-worker", "lockDuration": 10000}]
    })
    for task in resp.json():
        print("Processing result task", task["id"])
        # TODO: aggregate results from DB/Redis
        requests.post(f"{BASE_URL}/external-task/{task['id']}/complete", json={"workerId": "result-worker"})

while True:
    fetch_and_complete_result()
    time.sleep(2)
✅ Flow Recap
User triggers process in Camunda.

Camunda executes Vote Service Task → publishes job to vote-worker.

Python vote worker processes vote and completes task.

Camunda executes Result Service Task → publishes job to result-worker.

Python result worker aggregates results and completes task.

Process ends.

📊 Monitoring
Use Camunda Cockpit → http://localhost:31004/camunda/app/cockpit/default/#/

Use Camunda Admin → http://localhost:31004/camunda/app/admin/default/#/  
Manage users and authorizations.
