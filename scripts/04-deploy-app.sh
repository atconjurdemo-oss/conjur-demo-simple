#!/usr/bin/env bash
# 04-deploy-app.sh — Build and deploy the Incident Tracker webapp.
#
# Option A — Artifact Registry (default):
#   export PROJECT_ID=your-gcp-project
#   export REGION=europe-west1
#   bash scripts/04-deploy-app.sh
#
# Option B — GHCR (pre-built by GitHub Actions):
#   export GHCR_IMAGE=ghcr.io/<owner>/webapp:latest
#   bash scripts/04-deploy-app.sh

set -euo pipefail

TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)"

# ── Determine image ───────────────────────────────────────────────────────────
if [ -n "${GHCR_IMAGE:-}" ]; then
  IMAGE="${GHCR_IMAGE}"
  echo "==> Using pre-built GHCR image: ${IMAGE}"
else
  : "${PROJECT_ID:?Set PROJECT_ID or GHCR_IMAGE}"
  REGION="${REGION:-europe-west1}"
  REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/conjur-demo"
  IMAGE="${REGISTRY}/webapp:${TAG}"
  echo "==> [1/3] Building and pushing image (${TAG})..."
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
  gcloud artifacts repositories create conjur-demo \
    --repository-format=docker --location="${REGION}" 2>/dev/null || true
  if command -v docker &>/dev/null; then
    docker build -t "${IMAGE}" app/
    docker push "${IMAGE}"
  else
    gcloud builds submit app/ --tag "${IMAGE}" --project "${PROJECT_ID}"
  fi
fi

# ── Apply manifests ───────────────────────────────────────────────────────────
echo "==> Applying Kubernetes manifests..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/webapp/serviceaccount.yaml
kubectl apply -f k8s/webapp/configmap.yaml
kubectl apply -f k8s/mysql/statefulset.yaml
kubectl apply -f k8s/webapp/ingress.yaml

kubectl -n securetask get secret flask-secret &>/dev/null || \
  kubectl -n securetask create secret generic flask-secret \
    --from-literal=secret-key="$(openssl rand -hex 32)"

# ── Deploy ────────────────────────────────────────────────────────────────────
echo "==> Deploying webapp..."
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" k8s/webapp/deployment.yaml | kubectl apply -f -
kubectl -n securetask rollout status deployment/webapp --timeout=5m

EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<pending>')"
echo ""
echo "Done! Incident Tracker: http://${EXTERNAL_IP}/app"
echo "Next: bash scripts/05-verify.sh"
