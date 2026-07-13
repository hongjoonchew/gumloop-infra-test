#!/usr/bin/env bash
# Bootstrap Fleet + Multi-Cluster Services + Multi-Cluster Gateway
# for the Flask API deployment. Idempotent; safe to re-run.
#
# Preconditions:
#   - 3 GKE clusters already exist (VPC-native, private, Gateway API enabled)
#   - gcloud CLI authenticated (gcloud auth login)
#   - Caller has roles/container.admin + roles/gkehub.admin on the project
#
# Usage:
#   PROJECT_ID=gumloop-infra-interview \
#   CONFIG_CLUSTER=cluster-a \
#   CLUSTERS="cluster-a cluster-b cluster-c" \
#   ./infra/bootstrap-mcg.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${CONFIG_CLUSTER:?Set CONFIG_CLUSTER (Fleet membership name of the config cluster)}"
: "${CLUSTERS:?Set CLUSTERS as space-separated Fleet membership names}"

echo "==> Project: ${PROJECT_ID}"
echo "==> Config cluster: ${CONFIG_CLUSTER}"
echo "==> Workload clusters: ${CLUSTERS}"
echo

echo "==> [1/4] Verifying required APIs are enabled"
# Not enabling APIs autonomously (see gcloud skill). Fail loudly if any missing.
required_apis=(
  container.googleapis.com
  gkehub.googleapis.com
  multiclusterservicediscovery.googleapis.com
  multiclusteringress.googleapis.com
  trafficdirector.googleapis.com
)
for api in "${required_apis[@]}"; do
  if ! gcloud services list --enabled --project="${PROJECT_ID}" \
        --filter="config.name=${api}" --format="value(config.name)" --quiet | grep -q "${api}"; then
    echo "ERROR: API ${api} is not enabled on project ${PROJECT_ID}."
    echo "       Enable it with: gcloud services enable ${api} --project=${PROJECT_ID}"
    exit 1
  fi
done

echo "==> [2/4] Verifying all clusters are Fleet-registered"
for c in ${CLUSTERS}; do
  if ! gcloud container fleet memberships describe "${c}" \
        --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "ERROR: cluster ${c} is not registered to the Fleet."
    echo "       Register with: gcloud container fleet memberships register ${c} ..."
    exit 1
  fi
done

echo "==> [3/4] Enabling Multi-Cluster Services on the Fleet"
gcloud container fleet multi-cluster-services enable \
  --project="${PROJECT_ID}" --quiet

echo "==> [4/4] Enabling Multi-Cluster Gateway with config cluster ${CONFIG_CLUSTER}"
gcloud container fleet ingress enable \
  --config-membership="${CONFIG_CLUSTER}" \
  --project="${PROJECT_ID}" --quiet

echo
echo "==> Done. Next steps:"
echo "  1. helm upgrade --install app ./app/chart --set multiCluster.enabled=true \\"
echo "       (run against each of: ${CLUSTERS})"
echo "  2. helm upgrade --install gateway ./infra/gateway-chart \\"
echo "       (run against ${CONFIG_CLUSTER} only)"
