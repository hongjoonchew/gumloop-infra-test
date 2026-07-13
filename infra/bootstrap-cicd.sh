#!/usr/bin/env bash
# Bootstrap CI/CD infrastructure on GCP for GitHub Actions -> Artifact Registry
# + GKE deploy. Creates:
#   - Artifact Registry docker repo
#   - Workload Identity Federation pool + OIDC provider (GitHub)
#   - Deployer service account with least-privilege roles
#   - IAM binding letting the GitHub repo impersonate the SA (no keys)
#
# Idempotent; safe to re-run.
#
# Preconditions:
#   - gcloud CLI authenticated (gcloud auth login)
#   - Caller has roles/owner OR (roles/iam.workloadIdentityPoolAdmin
#     + roles/iam.serviceAccountAdmin + roles/artifactregistry.admin
#     + roles/resourcemanager.projectIamAdmin) on the project.
#   - Required APIs already enabled (script verifies, does not enable).
#
# Usage:
#   PROJECT_ID=gumloop-infra-interview \
#   GITHUB_REPO=owner/repo \
#   ./infra/bootstrap-cicd.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${GITHUB_REPO:?Set GITHUB_REPO in the form owner/repo}"

REGION="${REGION:-us-central1}"
AR_REPO="${AR_REPO:-app}"
WIF_POOL="${WIF_POOL:-github-pool}"
WIF_PROVIDER="${WIF_PROVIDER:-github-provider}"
SA_NAME="${SA_NAME:-gha-deployer}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Project:       ${PROJECT_ID}"
echo "==> Region:        ${REGION}"
echo "==> AR repo:       ${AR_REPO}"
echo "==> WIF pool:      ${WIF_POOL}"
echo "==> WIF provider:  ${WIF_PROVIDER}"
echo "==> Deployer SA:   ${SA_EMAIL}"
echo "==> GitHub repo:   ${GITHUB_REPO}"
echo

echo "==> [1/6] Verifying required APIs are enabled"
required_apis=(
  artifactregistry.googleapis.com
  container.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  sts.googleapis.com
  cloudresourcemanager.googleapis.com
)
for api in "${required_apis[@]}"; do
  if ! gcloud services list --enabled --project="${PROJECT_ID}" \
        --filter="config.name=${api}" --format="value(config.name)" --quiet | grep -q "${api}"; then
    echo "ERROR: API ${api} is not enabled on project ${PROJECT_ID}."
    echo "       Enable it with: gcloud services enable ${api} --project=${PROJECT_ID}"
    exit 1
  fi
done

echo "==> [2/6] Creating Artifact Registry repo (${AR_REPO} in ${REGION})"
if gcloud artifacts repositories describe "${AR_REPO}" \
      --location="${REGION}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
  echo "    already exists, skipping."
else
  gcloud artifacts repositories create "${AR_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Container images for the Flask API" \
    --project="${PROJECT_ID}" --quiet
fi

echo "==> [3/6] Creating deployer service account (${SA_EMAIL})"
if gcloud iam service-accounts describe "${SA_EMAIL}" \
      --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
  echo "    already exists, skipping."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="GitHub Actions deployer" \
    --project="${PROJECT_ID}" --quiet
fi

echo "==> [4/6] Granting project roles to ${SA_EMAIL}"
# artifactregistry.writer: push images
# container.developer:     get GKE credentials + apply workloads
for role in roles/artifactregistry.writer roles/container.developer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> [5/6] Creating Workload Identity pool + OIDC provider"
if gcloud iam workload-identity-pools describe "${WIF_POOL}" \
      --location=global --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
  echo "    pool ${WIF_POOL} already exists, skipping."
else
  gcloud iam workload-identity-pools create "${WIF_POOL}" \
    --location=global \
    --display-name="GitHub Actions" \
    --project="${PROJECT_ID}" --quiet
fi

POOL_NAME=$(gcloud iam workload-identity-pools describe "${WIF_POOL}" \
  --location=global --project="${PROJECT_ID}" --format="value(name)")

if gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER}" \
      --location=global --workload-identity-pool="${WIF_POOL}" \
      --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
  echo "    provider ${WIF_PROVIDER} already exists, skipping."
else
  gcloud iam workload-identity-pools providers create-oidc "${WIF_PROVIDER}" \
    --location=global \
    --workload-identity-pool="${WIF_POOL}" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
    --attribute-condition="attribute.repository == '${GITHUB_REPO}'" \
    --project="${PROJECT_ID}" --quiet
fi

echo "==> [6/6] Binding SA impersonation to repo ${GITHUB_REPO}"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
  --quiet >/dev/null

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"

echo
echo "==> Done."
echo
echo "Configure the GitHub repo (${GITHUB_REPO}) with:"
echo "  Repository variable  GCP_PROJECT_NUMBER = ${PROJECT_NUMBER}"
echo
echo "The deploy workflow references these values:"
echo "  workload_identity_provider: ${PROVIDER_RESOURCE}"
echo "  service_account:            ${SA_EMAIL}"
echo
echo "Image path pushed by CI:"
echo "  ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/app:<sha>"
