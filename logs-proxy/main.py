"""logs-proxy: exposes plain, unauthenticated-from-the-caller's-side URLs for
the two "Logs" config values the ProcessMining reader-service needs:

    GET /logs?app=<name>&tail=100     -> kubectl logs equivalent (AKS pod logs)
    GET /metrics?query=<promql>       -> Prometheus (managed) instant query

Runs INSIDE the AKS cluster as its own pod, so /logs uses the standard
in-cluster Kubernetes client pattern: the pod's own ServiceAccount token and
CA cert are auto-mounted by Kubernetes at the paths below -- no token minting
or storage needed. RBAC (get/list on pods, pods/log) is granted to that
ServiceAccount via the Role/RoleBinding in logs-proxy-rbac.yaml.

The token file IS rotated in place by the kubelet (~hourly), so it's read
fresh on every request rather than cached at startup -- caching it caused a
real outage: the pod ran past the first rotation and every request started
failing with 401 Unauthorized, silently (the reader on the other end treats
a failed poll as "no new logs" rather than an error).

/metrics still needs its own Azure AD identity with "Monitoring Data Reader"
on the Azure Monitor workspace (a subscription-level IAM grant) before it can
succeed -- see the conversation/README note next to this file.
"""
from __future__ import annotations

import os
from pathlib import Path

import httpx
from azure.identity import DefaultAzureCredential
from fastapi import FastAPI, HTTPException, Query

app = FastAPI(title="logs-proxy", version="1.0.0")

_SA_DIR = Path("/var/run/secrets/kubernetes.io/serviceaccount")
_IN_CLUSTER = _SA_DIR.exists()

if _IN_CLUSTER:
    K8S_API_SERVER = "https://kubernetes.default.svc"
    K8S_CA_CERT = str(_SA_DIR / "ca.crt")
    _k8s_verify: bool | str = K8S_CA_CERT
else:
    # Local/out-of-cluster testing fallback.
    K8S_API_SERVER = os.environ["K8S_API_SERVER"].rstrip("/")
    _static_token = os.environ["K8S_TOKEN"]
    _k8s_verify = False


def _k8s_token() -> str:
    """Re-read on every call -- the in-cluster token file is rotated in
    place roughly hourly, so anything cached at import time goes stale."""
    if _IN_CLUSTER:
        return (_SA_DIR / "token").read_text().strip()
    return _static_token

K8S_NAMESPACE_DEFAULT = os.getenv("K8S_NAMESPACE_DEFAULT", "default")

PROM_QUERY_ENDPOINT = os.environ.get("PROM_QUERY_ENDPOINT", "").rstrip("/")
PROM_SCOPE = "https://prometheus.monitor.azure.com/.default"

_credential = DefaultAzureCredential() if PROM_QUERY_ENDPOINT else None

_k8s_client = httpx.AsyncClient(verify=_k8s_verify, timeout=15.0)
_prom_client = httpx.AsyncClient(timeout=15.0)


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "service": "logs-proxy", "in_cluster": _IN_CLUSTER}


@app.get("/logs")
async def get_logs(
    app_label: str = Query(..., alias="app"),
    namespace: str = Query(K8S_NAMESPACE_DEFAULT),
    tail: int = Query(100, ge=1, le=5000),
):
    headers = {"Authorization": f"Bearer {_k8s_token()}"}

    pods_url = f"{K8S_API_SERVER}/api/v1/namespaces/{namespace}/pods"
    pods_resp = await _k8s_client.get(pods_url, headers=headers, params={"labelSelector": f"app={app_label}"})
    if pods_resp.status_code != 200:
        raise HTTPException(status_code=pods_resp.status_code, detail=f"pod list failed: {pods_resp.text}")

    items = pods_resp.json().get("items", [])
    if not items:
        raise HTTPException(status_code=404, detail=f"no running pods with label app={app_label} in namespace {namespace}")

    pod_name = items[0]["metadata"]["name"]

    log_url = f"{K8S_API_SERVER}/api/v1/namespaces/{namespace}/pods/{pod_name}/log"
    log_resp = await _k8s_client.get(log_url, headers=headers, params={"tailLines": tail})
    if log_resp.status_code != 200:
        raise HTTPException(status_code=log_resp.status_code, detail=f"log fetch failed: {log_resp.text}")

    return {"app": app_label, "namespace": namespace, "pod": pod_name, "logs": log_resp.text}


@app.get("/metrics")
async def get_metrics(query: str = Query(..., description="PromQL expression")):
    if not _credential or not PROM_QUERY_ENDPOINT:
        raise HTTPException(status_code=501, detail="PROM_QUERY_ENDPOINT not configured")

    token = _credential.get_token(PROM_SCOPE)
    headers = {"Authorization": f"Bearer {token.token}"}

    resp = await _prom_client.get(
        f"{PROM_QUERY_ENDPOINT}/api/v1/query",
        headers=headers,
        params={"query": query},
    )
    if resp.status_code != 200:
        raise HTTPException(status_code=resp.status_code, detail=f"prometheus query failed: {resp.text}")

    return resp.json()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
