#!/usr/bin/env bash
# 04-deploy-app.sh — Build and deploy the Incident Tracker webapp.
#
# Usage:
#   export PROJECT_ID=<gcp-project>
#   export REGION=europe-west1   # optional, default: europe-west1
#   bash scripts/04-deploy-app.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
REGION="${REGION:-europe-west1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/conjur-demo"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)"
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

echo "==> [2/3] Applying Kubernetes manifests..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/webapp/serviceaccount.yaml
kubectl apply -f k8s/webapp/configmap.yaml
kubectl apply -f k8s/mysql/statefulset.yaml
kubectl apply -f k8s/webapp/ingress.yaml

# Flask secret key (generated once, stable across restarts)
kubectl -n securetask get secret flask-secret &>/dev/null || \
  kubectl -n securetask create secret generic flask-secret \
    --from-literal=secret-key="$(openssl rand -hex 32)"

echo "==> [3/3] Deploying webapp..."
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" k8s/webapp/deployment.yaml | kubectl apply -f -
kubectl -n securetask rollout status deployment/webapp --timeout=5m

EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<pending>')"
echo ""
echo "Done! Incident Tracker: http://${EXTERNAL_IP}/app"
echo "Next: bash scripts/05-verify.sh"
