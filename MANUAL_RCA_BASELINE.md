# Manual RCA Baseline — 5 Case Scenarios

Purpose: a human-performed, ground-truth root cause analysis for five real
incidents on this AKS deployment, recorded **before** the ProcessMining
`llm_rca_investigator` agent analyzes the same evidence. Compare the
agent's output against the `Ground truth (for comparison)` block in each
scenario to measure its precision — correct root cause, correct affected
component, correct severity, and whether it needed any evidence a human
didn't.

Scenarios 1–3 are genuine incidents hit during this project's real AKS
deployment (not staged) — the evidence below is the actual investigation
trail. Scenarios 4–5 were reproduced live and controlled, specifically to
round out this baseline, with real evidence captured the same way.

All evidence was gathered exactly the way the agent will see it: via
`logs-proxy`'s `/logs?app=<name>` URLs (the same source the `kubectl_logs`
/ `generic_url_logs` reader polls) and direct `kubectl` (via
`az aks command invoke`, since no local kubectl exists on this machine).

---

## Executive summary (customer-facing)

Plain-language version of the five findings below — what went wrong, what
was done about it, and where things stand. Full technical detail (log
excerpts, exact commands, source-code root cause) is in the numbered
scenarios further down, for engineering audiences.

| # | Problem | Solution | Outcome |
|---|---|---|---|
| 1 | The voting app failed to start up at all — a naming clash between one of its settings and how the platform (Kubernetes) automatically wires services together. | Renamed the setting so it no longer collides. | **Fixed.** App has been stable since, zero downtime after the fix. |
| 2 | Votes were being silently lost — accepted by the app, but never actually saved, because of a mismatch in how the database table was defined versus how the app tried to write to it. | Corrected the database setup to match what the app needs. | **Fixed and verified** — test votes now save and count correctly. |
| 3 | The service that lets our monitoring tool read application logs quietly stopped working after about two hours, with no crash or alarm — it just went silent. | Fixed how it handled its internal security credential, so it no longer goes stale over time. | **Fixed.** Confirmed working continuously since. |
| 4 | If the database component ever gets restarted (routine maintenance, a hardware issue, etc.), all stored data is lost — it isn't currently set up to keep data through a restart. | Confirmed the system *itself* recovers automatically (no manual fix needed to get it running again). Data durability is a separate, known gap. | **Identified, not yet fixed.** Recommended before production use: add persistent storage so data survives a restart. |
| 5 | If the app's internal queue (Redis) is temporarily unavailable, the voting app doesn't fail gracefully — it shows a technical error page to the end user, which in this case included exposed internal debugging details. | Root cause identified precisely: one code path was missing error-handling that a sibling code path already had, and a developer debug setting was left on. | **Identified, not yet fixed.** Two straightforward fixes recommended before production use. |

**How to frame this to a customer:** three of five are real production
incidents that were found and fixed during deployment (#1–#3) — a normal,
healthy part of standing up a new system, each resolved same-day with a
clear before/after verification. The remaining two (#4–#5) were
deliberately tested rather than accidentally discovered, specifically to
build a track record *before* going live — both are pre-production
findings with clear, scoped fixes already identified, not open incidents.
That framing (caught early, understood precisely, fix already known) is a
stronger story than either hiding them or presenting them as ongoing
problems.

---

## Scenario 1 — `vote` crash-loop on startup

**Type:** genuine incident, occurred during initial deployment
**Affected component:** `vote`
**Severity:** Critical (service completely unavailable, `CrashLoopBackOff`)

### Symptom
`curl http://20.121.162.140/` failed to connect. `kubectl get pods` showed
`vote` with `RESTARTS: 2` within the first 20 seconds of the deployment.

### Evidence gathered
```
$ curl "http://104.45.175.71/logs?app=vote&tail=30"
Traceback (most recent call last):
  File "/usr/local/app/app.py", line 21, in <module>
    REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
ValueError: invalid literal for int() with base 10: 'tcp://10.0.5.189:6379'
```

### Investigation
1. Pod is crash-looping immediately on startup, before it can even bind a
   port — ruled out a runtime/traffic issue, this is a startup-time config
   problem.
2. The traceback pinpoints line 21 of `app.py`: parsing `REDIS_PORT` as an
   int fails because its value is `tcp://10.0.5.189:6379`, not a bare port
   number.
3. Nothing in the Deployment manifest (`vote-deployment.yaml`) sets
   `REDIS_PORT` to that value — only `REDIS_HOST` is set explicitly.
4. `10.0.5.189` is the `redis` Service's `ClusterIP` — recognized this as
   Kubernetes' legacy Docker-links-style service discovery: it
   auto-injects `<SERVICE_NAME>_PORT=tcp://<clusterIP>:<port>` into every
   pod's environment for every Service in the same namespace. A Service
   named `redis` exists, so every pod (including `vote` itself)
   automatically gets a `REDIS_PORT` env var it never asked for.

### Root cause
The application defined its own `REDIS_PORT` environment variable to allow
overriding the Redis port, not realizing Kubernetes reserves that exact
name for automatic service-discovery injection when a Service called
`redis` exists in the same namespace. The auto-injected value (a URI, not
an integer) collided with and shadowed the app's intended override,
crashing `int()` parsing on every startup.

### Fix
Renamed the application's override variable to `VOTE_REDIS_PORT` in
`vote/app.py`, which cannot collide with any Kubernetes-generated name.

### Verification
Rebuilt image, `kubectl rollout restart deployment vote` → new pod
`0` restarts, `curl http://20.121.162.140/` → `200`.

### Ground truth (for comparison)
```yaml
affected_component: vote
root_cause_category: configuration / environment-variable collision
root_cause_one_line: >
  App's own REDIS_PORT env var was shadowed by Kubernetes' auto-injected
  Service-discovery variable of the same name, breaking int() parsing.
evidence_needed:
  - vote pod log (Traceback + ValueError line) — sufficient alone to spot the crash
  - vote-deployment.yaml / redis-service.yaml — needed to explain WHY, not just WHAT
time_to_root_cause_human: ~2 minutes (log message names the exact line and bad value)
```

---

## Scenario 2 — `worker` crash-loop on first vote processed

**Type:** genuine incident, occurred during initial deployment
**Affected component:** `worker`
**Severity:** Critical (silent data loss — votes accepted by `vote` but never persisted)

### Symptom
`vote` accepted submissions successfully (`200 OK`), but
`SELECT vote, COUNT(id) FROM votes GROUP BY vote` on `db` returned `0
rows` even after votes were submitted. `worker`'s live log tail showed
only startup lines (`Connected to db`, `Connecting to redis`) with no
further activity — looked idle, not obviously broken.

### Evidence gathered
```
$ kubectl logs deploy/worker --previous --tail=30
Connected to db
Found redis at 10.0.5.189
Connecting to redis
Processing vote for 'a' by '61fadb12-1129-4153-86b2-e2b8519fb016'
Npgsql.PostgresException (0x80004005): 42703: column "voter_id" of relation "votes" does not exist
   at ... Worker.Program.UpdateVote(...) in /source/Program.cs:line 168
   at ... Worker.Program.Main(String[] args) in /source/Program.cs:line 53

$ kubectl exec deploy/db -- psql -U postgres -c '\d votes'
                       Table "public.votes"
 Column |          Type          | Collation | Nullable | Default
--------+------------------------+-----------+----------+---------
 id     | character varying(255) |           | not null |
 vote   | character varying(255) |           | not null |
```

### Investigation
1. `kubectl logs deploy/worker` (current pod) showed nothing useful — it
   had *already restarted* since the crash, so the crash evidence was
   gone from the live log. Had to use `kubectl logs --previous` to see
   the prior (crashed) instance's output.
2. That revealed the real error: `column "voter_id" of relation "votes"
   does not exist` (Postgres error `42703`, undefined column) — thrown
   from `UpdateVote()` at `Program.cs:168`.
3. Checked `\d votes` on the live table: it only has `id` and `vote`
   columns.
4. Cross-referenced `Program.cs`'s `CREATE TABLE IF NOT EXISTS` statement
   (the one that actually ran at startup) against its own `INSERT`/
   `UPDATE` statements in `UpdateVote()`: the `CREATE TABLE` declared
   `(id VARCHAR(255) UNIQUE, vote VARCHAR(255))`, but `UpdateVote()`
   inserts into `(voter_id, vote, created_at)` — columns the table was
   never given. A pre-existing bug in the original source, not something
   introduced by this deployment.
5. `restarts: 1` on the worker pod, confirmed the crash-and-restart cycle
   independently of the log evidence.

### Root cause
`worker/Program.cs`'s table-creation statement did not match the columns
its own insert/update logic used — an internal schema inconsistency in
the original source code. Every vote popped off the Redis queue crashed
the process on its first `INSERT`, which Kubernetes then restarted,
repeating indefinitely; votes were silently dropped from the queue
(popped, then lost on crash) with **no error visible from the `vote`
service itself**, since `vote` only knows the value reached Redis, not
whether `worker` successfully persisted it.

### Fix
Corrected the `CREATE TABLE` statement to match the columns actually used:
`id SERIAL PRIMARY KEY, voter_id VARCHAR(255) UNIQUE, vote VARCHAR(255),
created_at TIMESTAMP DEFAULT NOW()`. Dropped the (empty) mis-shaped table
so the corrected statement could recreate it cleanly.

### Verification
Rebuilt image, dropped stale table, `kubectl rollout restart deployment
worker`, submitted two votes → `worker` logged `Processing vote for 'a'
by '...'` / `'b'` with no crash, `SELECT ... GROUP BY vote` showed both
counted correctly.

### Ground truth (for comparison)
```yaml
affected_component: worker
root_cause_category: application bug / schema-code mismatch
root_cause_one_line: >
  CREATE TABLE statement didn't match the columns used by the INSERT/UPDATE
  logic in the same file, crashing on every vote processed.
evidence_needed:
  - worker's PREVIOUS pod log (current pod's log alone is misleading —
    shows only a healthy-looking restart, not the crash)
  - live table schema (\d votes) to confirm which version is actually running
  - Program.cs source, to see the CREATE TABLE / INSERT mismatch directly
time_to_root_cause_human: ~5 minutes (required realizing --previous logs were needed)
difficulty_note: >
  The single biggest trap in this one: the CURRENT pod's logs looked calm
  and gave no indication anything was wrong. An investigator (human or
  agent) that only reads the live log tail — without checking restart
  count or previous-instance logs — would conclude "no news is good news"
  and miss a critical data-loss bug entirely.
```

---

## Scenario 3 — `logs-proxy` silent 401 outage after ~2 hours uptime

**Type:** genuine incident, discovered indirectly via a downstream consumer
**Affected component:** `logs-proxy`
**Severity:** High (broke the entire kubectl-logs-as-URL integration, but with no crash/restart — invisible to basic pod-health checks)

### Symptom
The ProcessMining reader-service's ingest script reported `read 0 log
line(s)` / `nothing new to persist` even after resetting its local dedup
checkpoint file — expected to see hundreds of lines on a fresh checkpoint.
`logs-proxy`'s own pod showed `1/1 Running`, `0 restarts` — looked
completely healthy by every standard Kubernetes health signal.

### Evidence gathered
```
$ curl "http://104.45.175.71/logs?app=vote&tail=5"
{"detail":"pod list failed: {\"kind\":\"Status\",...,\"status\":\"Failure\",
\"message\":\"Unauthorized\",\"reason\":\"Unauthorized\",\"code\":401}"}

$ kubectl get pods -l app=logs-proxy
NAME                          READY   STATUS    RESTARTS   AGE
logs-proxy-55d854bcb4-hrkz4   1/1     Running   0          118m
```

### Investigation
1. The ProcessMining side's own reader code (`KubectlLogsReader._read_app`)
   **silently swallows `httpx.HTTPError`** — a deliberate design choice
   ("a pod being briefly unavailable shouldn't kill the whole poll"), but
   it meant the actual 401 never surfaced anywhere in that reader's own
   output. The zero-events result gave no clue *why*.
2. First (wrong) hypothesis: the dedup checkpoint file was stale.
   Reset it to empty, re-ran the ingest — still 0 lines. Ruled out.
3. Went one layer down and `curl`'d `logs-proxy` directly, bypassing the
   reader entirely — that's what surfaced the real `401 Unauthorized`
   from the Kubernetes API server itself.
4. `logs-proxy`'s pod had been `Running` for **118 minutes** — well past
   an hour. Recalled that Kubernetes rotates a pod's ServiceAccount token
   file in place roughly hourly (bound-token rotation), and checked
   `logs-proxy/main.py`'s source: the token was read **once**, at module
   import time, into a variable that was then reused for every request —
   never re-read afterward.

### Root cause
`logs-proxy` cached its own Kubernetes authentication token in memory at
process startup instead of re-reading it per request. The token file on
disk is rotated in place by the kubelet roughly hourly; once the process
ran past the first rotation, its cached copy went stale and every
subsequent call to the Kubernetes API returned `401`. No crash, no
restart, no visible symptom on the `logs-proxy` pod itself — only visible
as "zero results" three layers downstream, in a different project
entirely.

### Fix
Changed `main.py` to read the token file fresh on every incoming request
(`_k8s_token()` helper) instead of caching it as a module-level constant.

### Verification
Rebuilt, `kubectl rollout restart deployment logs-proxy`,
`curl http://104.45.175.71/logs?app=vote&tail=5` → `200` with real log
content.

### Ground truth (for comparison)
```yaml
affected_component: logs-proxy
root_cause_category: application bug / credential lifecycle (stale cached auth token)
root_cause_one_line: >
  ServiceAccount token cached once at startup went stale after Kubernetes'
  ~hourly in-place token rotation; every subsequent K8s API call got 401.
evidence_needed:
  - direct curl of logs-proxy's own /logs endpoint (bypassing the downstream
    consumer entirely) — the downstream consumer's silence was a dead end
  - logs-proxy pod AGE (118m > ~1hr rotation window) — the timing correlation
    IS the root-cause evidence here, not a log line
  - logs-proxy source code, to find the caching bug
time_to_root_cause_human: ~10 minutes (required ruling out a wrong hypothesis first)
difficulty_note: >
  No log line anywhere says "token expired" — Kubernetes' 401 response body
  gives no hint about *why* the token is invalid, and the failing component
  (logs-proxy) never restarted or showed unhealthy. Correlating pod AGE
  against a known Kubernetes platform behavior (hourly token rotation) was
  the only path to root cause; this is the hardest of the 5 scenarios for
  a log-pattern-only analyzer to catch without that platform knowledge.
```

---

## Scenario 4 — `db` pod deletion (live-reproduced)

**Type:** controlled live reproduction
**Affected component:** `db`, with a downstream effect on `worker`
**Severity:** Medium (self-healing, brief availability gap, and a real design gap: no persistent volume)

### Timeline (UTC)
| Time | Event |
|---|---|
| 11:31:13 | `kubectl delete pod -l app=db` issued |
| 11:31:13–~11:32:11 | New `db` pod `ContainerCreating`; `worker` retrying |
| 11:32:12 | New `db` pod `1/1 Running` |
| 11:32:50 | Test vote submitted → persisted correctly in the fresh table |

### Evidence gathered
```
$ curl "http://104.45.175.71/logs?app=worker&tail=20"
Waiting for db (Exception while connecting)
Waiting for db (Exception while connecting)
Waiting for db (Exception while connecting)
Waiting for db (Exception while connecting)
Waiting for db (Exception while connecting)
Connected to db
Found redis at 10.0.5.189
Connecting to redis
```

### Investigation
1. Deliberately deleted the `db` pod to simulate a node eviction / OOM
   kill / any involuntary pod loss.
2. `worker`'s log shows exactly 5 `Waiting for db (Exception while
   connecting)` retries (its own `OpenDbConnection` retry loop, 1-second
   interval) before reconnecting successfully — consistent with a ~5-6
   second gap between the old pod dying and the new one accepting
   connections.
3. Confirmed the Kubernetes Deployment controller recreated the pod
   automatically — no manual intervention needed, this is Kubernetes'
   normal self-healing behavior working as designed.
4. Confirmed the **application-level** consequence separately: since `db`
   runs `postgres:15-alpine` with no `PersistentVolumeClaim`, the new pod
   starts with a **completely empty** data directory. The `votes` table
   (and all prior vote data) was gone; `worker`'s `CREATE TABLE IF NOT
   EXISTS` silently recreated an empty table on reconnect, masking the
   data loss from any automated check that only looks at "does the table
   exist."

### Root cause
Kubernetes' pod-level self-healing worked correctly and is not itself a
bug — this scenario's actual root cause is a **deployment design gap**:
`db-deployment.yaml` provisions Postgres with no persistent storage, so
any pod replacement (deletion, eviction, node failure, rolling update)
silently discards all data with no error raised anywhere in the stack.

### Fix
Not fixed (acceptable for this demo's current scope) — documented as a
known gap in `ARCHITECTURE.md` §10. A real fix would add a
`PersistentVolumeClaim` + `volumeMounts` to `db-deployment.yaml` backed by
an Azure Disk.

### Verification
New pod reached `Running`, `worker` reconnected automatically, a
post-recovery test vote was submitted and confirmed present via direct
`psql` query.

### Ground truth (for comparison)
```yaml
affected_component: db (with worker as the visible downstream symptom)
root_cause_category: infrastructure design gap (no persistent storage)
root_cause_one_line: >
  db has no PersistentVolumeClaim, so any pod replacement silently wipes
  all data even though the service self-heals and looks "fixed."
evidence_needed:
  - worker's "Waiting for db" retry pattern (proves an outage occurred and
    roughly how long)
  - db-deployment.yaml (absence of volumes/volumeMounts is the actual root
    cause, and is NOT visible from logs alone)
  - the fact that a fresh SELECT after recovery returns a freshly-empty
    table rather than the pre-outage row count
time_to_root_cause_human: ~1 minute for the immediate "why did worker retry"
  question; the deeper "and that means data was silently lost" conclusion
  requires knowing to check the manifest, not just the logs.
difficulty_note: >
  This is the clearest test of whether an RCA agent looks past "the
  service recovered" to the manifest-level design gap underneath. A
  log-only analysis would likely conclude "transient outage, self-healed,
  no action needed" — technically true but missing the real finding.
```

---

## Scenario 5 — `redis` scaled to zero while a vote is submitted (live-reproduced)

**Type:** controlled live reproduction
**Affected component:** `vote`
**Severity:** High (unhandled exception, user-facing `500`, plus a real security exposure)

### Timeline (UTC)
| Time | Event |
|---|---|
| 11:33:35 | `kubectl scale deployment redis --replicas=0` |
| 11:33:4x | `POST /` to `vote` with `vote=b` → `500`, full Werkzeug debugger page returned to the client |
| 11:34:54 | `kubectl scale deployment redis --replicas=1`, rollout completes |
| after | Test vote submitted → `200 OK`, confirmed working |

### Evidence gathered
```
$ curl -X POST http://20.121.162.140/ -d "vote=b"
<!doctype html>
<html lang=en>
  <head>
    <title>redis.exceptions.ConnectionError: Error 111 connecting to redis:6379.
    Connection refused. // Werkzeug Debugger</title>
    ...
    <script>
      var CONSOLE_MODE = false, EVALEX = false, EVALEX_TRUSTED = false,
          SECRET = "N28dQcWdhoStVSo5vhmG";
    </script>
    ...
<h1>ConnectionError</h1>
<p class="errormsg">redis.exceptions.ConnectionError: Error 111 connecting to
redis:6379. Connection refused.</p>
<h2 class="traceback">Traceback (most recent call last)</h2>
  ... full interactive stack frames, with an "Open an interactive python
  shell in this frame" affordance per frame (PIN-gated) ...

$ curl "http://104.45.175.71/logs?app=vote&tail=15"
  File "/usr/local/app/app.py", line 50, in index
    push_vote(vote, voter_id, source='direct-ui')
  File "/usr/local/app/app.py", line 36, in push_vote
    get_redis().rpush('votes', json.dumps(data))
  ...
redis.exceptions.ConnectionError: Error 111 connecting to redis:6379. Connection refused.
```

### Investigation
1. Deliberately scaled `redis` to 0 to simulate the dependency being
   unavailable, then exercised the **browser form path** (`POST /`)
   specifically — not the `/vote` JSON API.
2. The response was not a clean error page — it was Flask's **interactive
   Werkzeug debugger**, because `FLASK_ENV=development` is set on the
   `vote` deployment (inherited from the reconstructed image's Dockerfile,
   matching the original image's build history). This is materially worse
   than a generic 500: it discloses full source paths, local variable
   values at every stack frame, and offers a PIN-gated in-browser Python
   console per frame.
3. Compared this against `vote/app.py`'s two Redis-writing code paths:
   - `POST /vote` (the JSON API, built for the Camunda worker) wraps its
     `push_vote()` call in `try/except redis.exceptions.RedisError` and
     returns a clean `503 {"error": ...}`.
   - `POST /` (`index()`, the direct browser-form path) calls
     `push_vote()` with **no exception handling at all** — an
     inconsistency between the two entry points into the same function.
4. `logs-proxy`'s `/logs?app=vote` confirms this is exactly what
   `kubectl logs` shows too — the traceback is real application output,
   not just an artifact of the HTTP debugger page.

### Root cause
Two compounding issues, both real:
1. **Missing error handling**: `index()`'s direct-UI vote path has no
   `try/except` around its Redis call, unlike the `/vote` JSON path in
   the same file — an inconsistency, not a deliberate design choice.
2. **Debug mode in a publicly-reachable deployment**: `FLASK_ENV=development`
   causes any unhandled exception (from #1, or any other future bug) to
   render Werkzeug's interactive debugger to the public internet instead
   of a generic error page — a genuine security exposure independent of
   this specific Redis-outage scenario.

### Fix
Not fixed yet — deliberately left as the finding for this RCA exercise.
Recommended fix: wrap `index()`'s `push_vote()` call in the same
`try/except redis.exceptions.RedisError` pattern already used in
`/vote`, returning a clean error page; and set `FLASK_ENV=production` (or
unset it) plus `debug=False` for anything with a public LoadBalancer IP.

### Verification
Restored `redis` to 1 replica, rollout completed, confirmed a subsequent
vote submission succeeds normally (`200 OK`).

### Ground truth (for comparison)
```yaml
affected_component: vote
root_cause_category: application bug (inconsistent error handling) +
  security misconfiguration (debug mode public-facing)
root_cause_one_line: >
  index()'s direct-UI vote path has no exception handling around its Redis
  call (unlike the JSON /vote path in the same file), and FLASK_ENV=development
  turns that gap into a publicly-exposed interactive debugger/RCE surface.
evidence_needed:
  - the actual HTTP response body (not just the pod log) to notice the
    Werkzeug debugger is being served publicly — the pod log alone shows
    only the traceback, not that it's also rendered to end users
  - vote/app.py source, comparing the two Redis-call sites, to see the
    try/except asymmetry
  - the Dockerfile / deployment env vars, to see FLASK_ENV=development
time_to_root_cause_human: ~3 minutes for the traceback; recognizing the
  SECOND finding (public debugger exposure) requires looking at the raw
  HTTP response, not just kubectl logs.
difficulty_note: >
  This scenario has TWO distinct findings of different types (a code bug
  and a security misconfiguration). An agent that stops at "Redis was
  down, that's the root cause" gets partial credit at best — the more
  valuable finding is the asymmetric error handling AND the debug-mode
  exposure, neither of which is visible from the pod logs alone.
```

---

## Summary table

| # | Component | Category | Severity | Evidence source(s) needed |
|---|---|---|---|---|
| 1 | vote | config / env-var collision | Critical | pod logs only |
| 2 | worker | app bug / schema mismatch | Critical | previous-pod logs + live DB schema + source |
| 3 | logs-proxy | app bug / credential lifecycle | High | direct endpoint probe + pod age + source |
| 4 | db (→ worker) | infra design gap (no PVC) | Medium | worker logs + manifest (not visible from logs alone) |
| 5 | vote | app bug + security misconfig | High | HTTP response body + source diff + deployment env |

Every scenario here needed **more than one evidence source** to reach the
real root cause — plain log-line pattern matching alone (what
`FluentdSeverityAnalyzer` currently does: count ERROR/WARN per
`server_id`) would catch that *something* is wrong in scenarios 1, 2, 3,
and 5, but would not by itself explain *why*, and would very likely miss
scenario 4's actual finding entirely (the log pattern there looks like
"transient issue, self-healed" — technically true, but not the real
story). Use this table to gauge how much of each root cause the agent's
`llm_rca_investigator` reaches from `EVENT_LOG` evidence alone versus
what required a human going one layer deeper.
