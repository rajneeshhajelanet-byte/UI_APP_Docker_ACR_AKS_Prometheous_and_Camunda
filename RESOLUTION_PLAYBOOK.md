# Resolution Playbook — Exact Commands, for Future Automated Remediation

Companion to `MANUAL_RCA_BASELINE.md`. That document is about *diagnosis*
(what's the root cause); this one is about *resolution* — the exact,
copy-pasteable commands that fixed each incident, structured the way a
remediation agent would need them: **Diagnose → Fix → Verify**.

## The honest finding first

Your remediation system today (`config/modules.yaml` → `remediation:`)
is explicitly **restart-only in V1** — `VALIDATE -> allow-list check
(restart-only in V1)`. Mapping that against these five real incidents:

| # | Real fix required | Would a restart alone have fixed it? | Automatable under today's restart-only policy? |
|---|---|---|---|
| 1 | Code change (rename env var) + rebuild + redeploy | **No** — would crash-loop again identically | ❌ No |
| 2 | Code change (fix schema) + rebuild + redeploy + drop stale table | **No** — would crash on the first vote again | ❌ No |
| 3 | Code change (stop caching token) + rebuild + redeploy | **No** — would just go stale again ~1hr later | ❌ No |
| 4 | *Nothing* — Kubernetes' own Deployment controller already restarts a deleted/evicted pod automatically | **Yes**, and it already happened without any remediation system involved | ✅ Yes (but redundant — the platform does this natively) |
| 5 | Code change (add error handling) + config change (disable debug mode) + rebuild + redeploy | **No** — would fail the same way on the next Redis blip | ❌ No |

**The takeaway:** 4 of these 5 realistic incidents needed an actual source
code fix, not a restart. A restart-only remediation policy would correctly
handle *transient infrastructure* failures (scenario 4's shape) but is
structurally incapable of resolving *application bugs* (scenarios 1, 2, 3,
5) — restarting a pod running broken code just produces the same crash
again. For AI to meaningfully help with this class of incident, its
realistic near-term role is **precise RCA + a proposed code fix for a
human to review and merge** (which is exactly what `llm_rca_investigator`
already does) — not autonomous code deployment, which is a much larger,
riskier capability than what "restart-only" remediation implies. Worth
keeping this distinction explicit as the remediation roadmap evolves
beyond V1.

---

## Scenario 1 — `vote` REDIS_PORT collision

**Diagnose:**
```powershell
curl "http://104.45.175.71/logs?app=vote&tail=30"
# -> ValueError: invalid literal for int() ... 'tcp://10.0.5.189:6379'
```

**Fix** (code change — `vote/app.py`):
```python
# before
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
# after
REDIS_PORT = int(os.getenv('VOTE_REDIS_PORT', 6379))
```
```powershell
az acr build --registry obsdemoacr01 --image vote:latest ./vote
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl rollout restart deployment vote && kubectl rollout status deployment vote --timeout=60s"
```

**Verify:**
```powershell
curl -X POST http://20.121.162.140/ -d "vote=a"        # expect 200
curl "http://104.45.175.71/logs?app=vote&tail=15"       # expect no traceback
```

---

## Scenario 2 — `worker` schema mismatch

**Diagnose:**
```powershell
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl exec deploy/db -- psql -U postgres -c 'SELECT vote, COUNT(id) FROM votes GROUP BY vote;' && kubectl logs deploy/worker --previous --tail=30 && kubectl exec deploy/db -- psql -U postgres -c '\d votes'"
```

**Fix** (code change — `worker/Program.cs`):
```csharp
// before
command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
    id VARCHAR(255) NOT NULL UNIQUE,
    vote VARCHAR(255) NOT NULL
)";
// after
command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    voter_id VARCHAR(255) NOT NULL UNIQUE,
    vote VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
)";
```
```powershell
az acr build --registry obsdemoacr01 --image worker:latest ./worker
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl exec deploy/db -- psql -U postgres -c 'DROP TABLE IF EXISTS votes;' && kubectl rollout restart deployment worker && kubectl rollout status deployment worker --timeout=60s"
```
*(the `DROP TABLE` only touches an empty, mis-shaped table — confirmed
`0 rows` in the diagnose step before running it)*

**Verify:**
```powershell
curl -X POST http://20.121.162.140/ -d "vote=a"
curl -X POST http://20.121.162.140/ -d "vote=b"
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl exec deploy/db -- psql -U postgres -c 'SELECT vote, COUNT(id) FROM votes GROUP BY vote;'"
# -> expect both 'a' and 'b' counted
```

---

## Scenario 3 — `logs-proxy` stale token

**Diagnose:**
```powershell
curl "http://104.45.175.71/logs?app=vote&tail=5"    # -> 401 Unauthorized
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl get pods -l app=logs-proxy"     # check AGE vs ~60min rotation window
```

**Fix** (code change — `logs-proxy/main.py`):
```python
# before: read once at import time
K8S_TOKEN = (_SA_DIR / "token").read_text().strip()
...
headers = {"Authorization": f"Bearer {K8S_TOKEN}"}

# after: read fresh every request
def _k8s_token() -> str:
    if _IN_CLUSTER:
        return (_SA_DIR / "token").read_text().strip()
    return _static_token
...
headers = {"Authorization": f"Bearer {_k8s_token()}"}
```
```powershell
az acr build --registry obsdemoacr01 --image logs-proxy:latest ./logs-proxy
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl rollout restart deployment logs-proxy && kubectl rollout status deployment logs-proxy --timeout=60s"
```

**Verify:**
```powershell
curl "http://104.45.175.71/logs?app=vote&tail=5"     # -> 200 with real log content
```

---

## Scenario 4 — `db` pod deletion (self-healing, no code fix applied)

**Diagnose:**
```powershell
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl get pods -l app=db"
curl "http://104.45.175.71/logs?app=worker&tail=20"   # -> 'Waiting for db' retries, then 'Connected to db'
```

**Fix applied:** none — Kubernetes' Deployment controller recreates a
deleted pod automatically; no remediation action needed or possible to
speed this up meaningfully.

**Recommended fix, NOT applied** (would need a manifest change + apply,
outside restart-only scope):
```yaml
# db-deployment.yaml — add a PersistentVolumeClaim, mount it at postgres's data dir
volumeMounts:
  - name: pgdata
    mountPath: /var/lib/postgresql/data
volumes:
  - name: pgdata
    persistentVolumeClaim:
      claimName: db-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
```

**Verify (self-heal only):**
```powershell
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl get pods -l app=db"   # -> 1/1 Running within ~1 min
curl -X POST http://20.121.162.140/ -d "vote=a"   # -> 200, confirms app-level recovery too
```

---

## Scenario 5 — `vote` unhandled Redis exception (no code fix applied)

**Diagnose:**
```powershell
curl -X POST http://20.121.162.140/ -d "vote=b"       # -> 500, Werkzeug debugger page
curl "http://104.45.175.71/logs?app=vote&tail=15"      # -> traceback at app.py:50 -> app.py:36
```

**Recommended fix, NOT applied** (deliberately left as the finding —
`vote/app.py`):
```python
# index() currently has no error handling around push_vote():
if request.method == 'POST':
    vote = request.form['vote']
    push_vote(vote, voter_id, source='direct-ui')

# recommended, matching the pattern already used in /vote:
if request.method == 'POST':
    vote = request.form['vote']
    try:
        push_vote(vote, voter_id, source='direct-ui')
    except redis.exceptions.RedisError as exc:
        app.logger.error('Error storing vote: %s', exc)
        return render_template('index.html', option_a=option_a, option_b=option_b,
                                hostname=hostname, vote=None, error=str(exc)), 503
```
```python
# vote/app.py, __main__ block — also recommended, separately:
app.run(host='0.0.0.0', port=int(os.getenv('PORT', 5000)), debug=False, use_reloader=False, threaded=True)
```
```yaml
# vote-deployment.yaml — remove or override the inherited FLASK_ENV=development
env:
  - name: FLASK_ENV
    value: "production"
```

**Verify (once applied):**
```powershell
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl scale deployment redis --replicas=0"
curl -X POST http://20.121.162.140/ -d "vote=b"        # expect a clean 503, not a debugger page
az aks command invoke -g rg-observability-demo -n aks-observability-demo `
  --command "kubectl scale deployment redis --replicas=1 && kubectl rollout status deployment redis --timeout=60s"
curl -X POST http://20.121.162.140/ -d "vote=b"        # expect 200 again
```

---

## Using this for automated remediation

If/when the remediation system expands past restart-only, scenarios 1–3
and the recommended fixes for 4–5 are already in a directly
machine-actionable shape: a source diff + an `az acr build` + an
`az aks command invoke` rollout. The realistic staged path:

1. **Now:** RCA agent diagnoses correctly (compare against
   `MANUAL_RCA_BASELINE.md`'s ground truth), proposes the fix from this
   playbook, a human applies it — exactly the current `llm_rca_investigator`
   → human-in-the-loop shape.
2. **Next:** agent opens a PR with the exact diff shown above, human
   merges — still no autonomous code execution, but removes the
   copy-paste step.
3. **Later, higher trust:** agent runs the `az acr build` +
   `kubectl rollout restart` sequence itself for a pre-approved, narrow
   allow-list of fixes (e.g. "rename this exact env var") — a much
   narrower automation than "let the agent write and deploy arbitrary
   code," and worth treating as a distinct, deliberate policy expansion
   rather than a natural extension of restart-only.
