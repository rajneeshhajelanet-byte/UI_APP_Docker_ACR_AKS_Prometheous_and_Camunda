## We are monitoring Camunda's resource consumption and performance metrics in Prometheus, while viewing application execution logs via kubectl logs

<img width="959" height="374" alt="image" src="https://github.com/user-attachments/assets/bd14d9b6-4e93-487d-8157-f4f10b6d4ee0" />

Application:

<img width="946" height="275" alt="image" src="https://github.com/user-attachments/assets/638fc4e0-7970-43a3-afbb-f375dcd8e53c" />

 log:
# Vote 1 (Option A)
[2026-08-03 05:54:00,391] INFO in app: Received vote for a
[2026-08-03 05:54:00 +0000] [15] [INFO] Received vote for a
127.0.0.1 - - [03/Aug/2026:05:54:00 +0000] "POST / HTTP/1.1" 200 1697 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
127.0.0.1 - - [03/Aug/2026:05:54:00 +0000] "GET /static/stylesheets/style.css HTTP/1.1" 304 0 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

# Vote 2 (Option B)
[2026-08-03 05:54:00,755] INFO in app: Received vote for b
[2026-08-03 05:54:00 +0000] [14] [INFO] Received vote for b
127.0.0.1 - - [03/Aug/2026:05:54:00 +0000] "POST / HTTP/1.1" 200 1697 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
127.0.0.1 - - [03/Aug/2026:05:54:00 +0000] "GET /static/stylesheets/style.css HTTP/1.1" 304 0 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

# Vote 3 (Option A)
[2026-08-03 05:54:33,920] INFO in app: Received vote for a
[2026-08-03 05:54:33 +0000] [12] [INFO] Received vote for a
127.0.0.1 - - [03/Aug/2026:05:54:33 +0000] "POST / HTTP/1.1" 200 1697 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
127.0.0.1 - - [03/Aug/2026:05:54:33 +0000] "GET /static/stylesheets/style.css HTTP/1.1" 304 0 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

# Vote 4 (Option B)
[2026-08-03 05:54:35,985] INFO in app: Received vote for b
[2026-08-03 05:54:35 +0000] [15] [INFO] Received vote for b
127.0.0.1 - - [03/Aug/2026:05:54:35 +0000] "POST / HTTP/1.1" 200 1697 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
127.0.0.1 - - [03/Aug/2026:05:54:36 +0000] "GET /static/stylesheets/style.css HTTP/1.1" 304 0 "http://localhost:5000/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

<img width="955" height="469" alt="image" src="https://github.com/user-attachments/assets/f7987129-7f73-40ec-b9ba-34a06ccc704f" />

### 🛠️ Step-by-Step Deployment & Commands
1. Port Forwarding (K8s to Local)
Forward the Camunda Engine REST & Cockpit service port to 8081:

PowerShell
kubectl port-forward svc/camunda 8081:8080
2. Deploy the BPMN Process Diagram
Deploy vote.bpmn from the project repository:

PowerShell
curl.exe -X POST "http://localhost:8081/engine-rest/deployment/create" `
  -F "deployment-name=vote-deployment" `
  -F "data=@.\worker-camunda\vote.bpmn"
3. Start a Workflow Instance via REST
Trigger the VoteProcess workflow instance with parameters:

PowerShell
$body = @{
    variables = @{
        vote = @{ value = "a"; type = "String" }
    }
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8081/engine-rest/process-definition/key/VoteProcess/start" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body
4. Run External Task Worker
Execute the Python polling worker:

PowerShell
python worker-camunda/Camundaflow.py

The system implements a **Dual-Path Execution Architecture** allowing votes to enter the processing pipeline either directly through the user interface or via a Camunda BPMN workflow process.

```mermaid
flowchart TD
    subgraph DUAL_PATH ["🏛️ DUAL-PATH ARCHITECTURE"]
        direction TB

        subgraph PATH_DIRECT ["Path 1: Direct User Action"]
            UI["🖥️ Web UI<br/><code>(:5000)</code>"]
        end

        subgraph PATH_CAMUNDA ["Path 2: Camunda BPMN Orchestration"]
            ENGINE["⚡ Camunda Engine<br/><code>(:8081)</code>"]
            WORKER["🐍 Python Task Worker"]
        end

        APP["🔥 Flask Vote App<br/><code>(Tagged: DIRECT UI)</code>"]
        DB[("💾 Redis / PostgreSQL DB")]
    end

    UI -->|HTTP Direct POST| APP
    ENGINE -->|REST Start / Poll| WORKER
    WORKER -->|HTTP Orchestrated POST| APP
    APP -->|Pushes Vote Data| DB

    style DUAL_PATH fill:#fafafa,stroke:#333,stroke-width:2px
    style PATH_DIRECT fill:#e6f3ff,stroke:#2b6cb0,stroke-width:1px
    style PATH_CAMUNDA fill:#fff5eb,stroke:#c05621,stroke-width:1px
    style UI fill:#ebf8ff,stroke:#3182ce,color:#2b6cb0,stroke-width:2px
    style ENGINE fill:#fffaf0,stroke:#dd6b20,color:#c05621,stroke-width:2px
    style WORKER fill:#feebc8,stroke:#d69e2e,color:#744210,stroke-width:2px
    style APP fill:#e6fffa,stroke:#319795,color:#234e52,stroke-width:2px
    style DB fill:#edf2f7,stroke:#4a5568,color:#1a202c,stroke-width:2px



