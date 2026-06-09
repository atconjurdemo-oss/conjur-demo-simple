#!/usr/bin/env bash
# 04-deploy-app.sh
# Builds and deploys the Flask app + MySQL to GKE.
#
# Usage:
#   export PROJECT_ID=<gcp-project>
#   export REGION=europe-west1
#   export DOMAIN=myapp.duckdns.org
#   bash scripts/04-deploy-app.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${DOMAIN:?Set DOMAIN}"
REGION="${REGION:-europe-west1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/conjur-demo"
IMAGE="${REGISTRY}/webapp:$(git rev-parse --short HEAD 2>/dev/null || echo latest)"

echo "==> [1/4] Building and pushing image..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
gcloud artifacts repositories create conjur-demo \
  --repository-format=docker --location="${REGION}" 2>/dev/null || true
docker build -t "${IMAGE}" app/
docker push "${IMAGE}"

echo "==> [2/4] Applying k8s manifests..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/webapp/serviceaccount.yaml
sed "s|PLACEHOLDER_DOMAIN|${DOMAIN}|g" k8s/webapp/configmap.yaml | kubectl apply -f -

echo "==> [3/4] Deploying MySQL and webapp..."
kubectl apply -f k8s/mysql/statefulset.yaml
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" k8s/webapp/deployment.yaml | kubectl apply -f -
sed "s|PLACEHOLDER_DOMAIN|${DOMAIN}|g" k8s/webapp/ingress.yaml | kubectl apply -f -

echo "==> [4/4] Waiting for rollout..."
kubectl -n securetask rollout status deployment/webapp --timeout=5m

echo ""
echo "Done! App: https://${DOMAIN}/app"
echo "Next: bash scripts/05-verify.sh"
