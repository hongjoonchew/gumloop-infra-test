# observability

Helm umbrella chart that stands up a VictoriaMetrics cluster and a `vmagent`
scraper. Together they collect the `/metrics` endpoint exposed by the Flask
app (via `prometheus-flask-exporter`) and make it queryable in PromQL.

## Topology

```
 Flask pods (/metrics)  ──scrape──►  vmagent  ──remote_write──►  vminsert
                                                                    │
                                                                    ▼
                                                                vmstorage (2 replicas, PVC)
                                                                    ▲
                                                     PromQL  ─────  vmselect
```

- `vminsert` — accepts writes on port 8480, Prometheus-compatible endpoint at
  `/insert/0/prometheus/`.
- `vmstorage` — stateful, PVC-backed (10Gi, 7d retention in this demo).
- `vmselect` — Prometheus-compatible query API on port 8481 at
  `/select/0/prometheus/`.
- `vmagent` — auto-discovers pods with `prometheus.io/scrape: "true"`.

## Install

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm dep update ./observability
helm upgrade --install observability ./observability \
  -n monitoring --create-namespace
```

## Verify

```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/observability-victoria-metrics-cluster-vmselect 8481:8481
```

Query examples (Prometheus-compatible API):

```bash
# Requests per second, broken down by HTTP status code
curl -sG http://localhost:8481/select/0/prometheus/api/v1/query \
  --data-urlencode 'query=sum by (status) (rate(flask_http_request_total[5m]))'

# 4xx / 5xx hotspots per route in the last 5 minutes
curl -sG http://localhost:8481/select/0/prometheus/api/v1/query \
  --data-urlencode 'query=sum by (status,path) (increase(flask_http_request_total{status=~"4..|5.."}[5m]))'

# p95 request latency per route
curl -sG http://localhost:8481/select/0/prometheus/api/v1/query \
  --data-urlencode 'query=histogram_quantile(0.95, sum by (le,path) (rate(flask_http_request_duration_seconds_bucket[5m])))'
```

## Prerequisites on the app side

The app chart must render with `metrics.enabled: true` (the default). This
adds `prometheus.io/scrape`, `prometheus.io/port`, and `prometheus.io/path`
pod annotations that `vmagent` matches on.
