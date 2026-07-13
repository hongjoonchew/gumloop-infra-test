# SETUP

Working notes for the Flask API deployment. Captures decisions made so far and open items.

## Layout

```
app/
├── main.py            # Flask app, single GET / health-check
├── requirements.txt   # flask, gunicorn, prometheus-flask-exporter
├── Dockerfile         # python:3.12-alpine3.20, runs gunicorn
└── chart/             # Workload chart — installs to every workload cluster
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── _helpers.tpl
        ├── deployment.yaml
        ├── service.yaml
        ├── hpa.yaml
        ├── pdb.yaml
        ├── serviceexport.yaml    # gated on multiCluster.enabled
        └── backendconfig.yaml    # gated on cloudArmor.enabled

infra/
├── bootstrap-mcg.sh   # Enables Fleet MCS + MCG on project (idempotent)
├── bootstrap-cicd.sh  # Creates AR repo + WIF pool/provider + deployer SA
└── gateway-chart/     # Config-cluster-only chart (installed once)
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── _helpers.tpl
        ├── gateway.yaml     # gke-l7-global-external-managed-mc
        └── httproute.yaml   # routes to ServiceImport (MCS-derived)

.github/workflows/
├── ci.yml             # pytest on PR + main
└── deploy.yml         # build → Artifact Registry → helm upgrade on GKE
```

## Container image

Base: `python:3.12-alpine3.20` (Alpine's current LTS line).

Build & run locally:

```
docker build -t app:0.1.0 app/
docker run -p 8080:8080 app:0.1.0
```

## Kubernetes (Helm)

Baseline chart ships a Deployment + ClusterIP Service. Probes hit `/`
(matches `main.py:5`).

```
helm upgrade --install app ./app/chart
helm upgrade --install app ./app/chart \
  --set image.repository=ghcr.io/you/app \
  --set image.tag=0.1.0 \
  --set replicaCount=3
```

Chart now includes HPA (CPU-based, 2–5 replicas, 70% target) and a
PodDisruptionBudget (`minAvailable: 1`). Both toggle via
`autoscaling.enabled` / `podDisruptionBudget.enabled` in `values.yaml`.

Intentionally omitted from baseline (add when needed):
Ingress, ServiceAccount/RBAC, ConfigMap/Secret, NetworkPolicy.

## Capacity sizing

Target load: **100–1000 rpm** during an 8h/day active window
(~1.7–17 rps peak). One API, JSON health-check, no downstream calls.

Per-pod memory (assuming gunicorn — see caveat below):

| Component                                | Steady   |
| ---------------------------------------- | -------- |
| Python 3.12 interpreter                  | ~20 MB   |
| Flask + Werkzeug                         | ~15 MB   |
| Gunicorn master + 2 sync workers         | ~60–80 MB |
| Request buffers @ 17 rps                 | <5 MB    |
| **Total working set**                    | **~100–120 MB** |

Applied resources in `values.yaml`:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

~2× headroom on the memory limit covers GC spikes and gunicorn worker
recycling.

## DDoS posture

Pod `resources.limits` do **not** defend against DDoS — by the time
traffic reaches the container, the attack has already succeeded at the
layer that matters. Pod limits contain a *single compromised pod* so it
can't starve the node; that is their real value.

Actual defenses, in order of importance:

1. **Edge**: CloudFlare / AWS Shield / GCP Cloud Armor — only real
   volumetric defense.
2. **Ingress rate limiting**: NGINX `limit_req` or Envoy local rate
   limiter, per-IP.
3. **HPA**: absorb legitimate 100→1000 rpm surges without paging.
4. **PodDisruptionBudget**: prevents scale-down from dropping to zero
   during an attack.
5. **Gunicorn `--max-requests` + `--timeout`**: bound slow-loris memory
   growth per worker.

## Runtime

The container runs gunicorn:

```
gunicorn -w 2 -k sync -b 0.0.0.0:8080 \
  --max-requests 1000 --max-requests-jitter 100 --timeout 30 main:app
```

`main.py:12` still contains `app.run(debug=True)` — that path only fires
when the module is executed directly (`python main.py`) for local dev.
Gunicorn imports `main:app`, so it never runs.

## Multi-Cluster Gateway

Fronting three GKE clusters with a single global entrypoint via GCP
Multi-Cluster Gateway (MCG).

```
Users → Cloud Armor → MCG (gke-l7-global-external-managed-mc)
                       │
              ┌────────┼────────┐
           cluster-a cluster-b cluster-c
           (each: Deployment + Service + ServiceExport)
```

**Project**: `gumloop-infra-interview`.

**One-time bootstrap** (`infra/bootstrap-mcg.sh`) enables:
- Multi-Cluster Services on the Fleet
- Multi-Cluster Gateway controller, bound to a designated **config cluster**

The script does NOT enable APIs, create clusters, register Fleet
memberships, or create the Cloud Armor policy — those are
user-authorized steps. The script fails loudly if any precondition is
missing.

**Deploy:**

```bash
# Every workload cluster (3x):
helm upgrade --install app ./app/chart \
  --set multiCluster.enabled=true \
  --set cloudArmor.enabled=true \
  --set cloudArmor.policyName=<policy-name>

# Config cluster only (1x):
helm upgrade --install gateway ./infra/gateway-chart \
  --set hostname=api.example.com
```

The `HTTPRoute` points at a `ServiceImport` that MCS derives from the
`ServiceExport`s emitted by each workload cluster. The gateway chart's
`backend.serviceName` must match the app chart's fullname.

## CI/CD

GitHub Actions push images to Artifact Registry and roll out via Helm
against a target GKE cluster. Auth is keyless via Workload Identity
Federation — no long-lived service-account JSON in the repo.

**Workflows**

- `.github/workflows/ci.yml` — runs `pytest` on PRs and pushes to main.
- `.github/workflows/deploy.yml` — on push to `main` (paths: `app/**`)
  or manual dispatch, builds the image, pushes to
  `us-central1-docker.pkg.dev/gumloop-infra-interview/app/app:<sha>`,
  then `helm upgrade --install app ./app/chart` against the target
  cluster (default `cluster-a` in `us-central1`).

**One-time bootstrap** (`infra/bootstrap-cicd.sh`):

```bash
PROJECT_ID=gumloop-infra-interview \
GITHUB_REPO=<owner>/<repo> \
./infra/bootstrap-cicd.sh
```

Creates:
- Artifact Registry docker repo `app` in `us-central1`
- Deployer SA `gha-deployer@…` with `roles/artifactregistry.writer`
  and `roles/container.developer` (project-scoped)
- WIF pool `github-pool` + OIDC provider `github-provider` with
  `attribute-condition` scoped to `${GITHUB_REPO}` — only that repo's
  workflow runs can impersonate the SA
- IAM binding: the repo's OIDC principalSet → `roles/iam.workloadIdentityUser`
  on the SA

The script does NOT enable APIs, create GKE clusters, or grant broader
IAM. It prints the exact `GCP_PROJECT_NUMBER` value to set as a GitHub
repository variable — the workflow reads it via `vars.GCP_PROJECT_NUMBER`
to build the provider resource name.

**Extending to all 3 clusters**: current deploy job targets a single
cluster. Convert `jobs.build-deploy` to a matrix over
`cluster-a/b/c` and set `--set multiCluster.enabled=true` on the helm
step to emit `ServiceExport`s for the Multi-Cluster Gateway.

## Open items

- **TLS**: out of scope for now. Gateway chart has `tls.enabled=false`
  by default; wire in Certificate Manager pre-shared certs when needed.
- **Cloud Armor policy**: created out-of-band (WAF + per-IP rate limits),
  passed by name via `cloudArmor.policyName`.
- **ServiceAccount / RBAC**, **NetworkPolicy**, **ConfigMap/Secret**
  wiring: add when the app grows beyond a single stateless endpoint.
- **Memory-based HPA metric**: not added; CPU is the right signal for
  this workload. Revisit if the app starts caching or buffering.

## Observability

The app is instrumented with `prometheus-flask-exporter`, which exposes
`/metrics` on the same 8080 port and auto-labels every request with
`method`, `path`, and `status`. Key series:

- `flask_http_request_total{method,path,status}` — counter, per response code
- `flask_http_request_duration_seconds_bucket{le,path}` — latency histogram

When `metrics.enabled` is true in `values.yaml` (default), the deployment
emits `prometheus.io/scrape`, `prometheus.io/port`, `prometheus.io/path`
pod annotations that `vmagent` matches on.

### VictoriaMetrics cluster

Umbrella chart at `observability/` deploys the split-role VM cluster
(`vminsert` + `vmstorage` + `vmselect`) plus `vmagent` as the scraper.

```
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm dep update ./observability
helm upgrade --install observability ./observability \
  -n monitoring --create-namespace
```

### Sample PromQL

```promql
# RPS broken down by HTTP status code
sum by (status) (rate(flask_http_request_total[5m]))

# 4xx / 5xx hotspots per route
sum by (status,path) (increase(flask_http_request_total{status=~"4..|5.."}[5m]))

# p95 latency per route
histogram_quantile(0.95,
  sum by (le,path) (rate(flask_http_request_duration_seconds_bucket[5m])))
```

Port-forward `vmselect` (`svc/observability-victoria-metrics-cluster-vmselect:8481`)
and hit `/select/0/prometheus/api/v1/query` to run these.

Demo endpoints in `main.py` drive real 4xx / 5xx traffic: `GET /notfound`
(404) and `GET /boom` (500) round out the status-code label space.
