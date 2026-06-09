#!/usr/bin/env bash
# 04-deploy-app.sh
# Builds the Docker image locally, pushes to Artifact Registry, deploys to GKE.
#
# Usage:
#   export PROJECT_ID=<gcp-project>
#   export REGION=europe-west1         # optional, default: europe-west1
#   bash scripts/04-deploy-app.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
REGION="${REGION:-europe-west1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/conjur-demo"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)"
IMAGE="${REGISTRY}/webapp:${TAG}"

echo "==> [1/4] Building image locally..."
docker build -t "${IMAGE}" app/

echo "==> [2/4] Pushing to Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
gcloud artifacts repositories create conjur-demo \
  --repository-format=docker --location="${REGION}" 2>/dev/null || true
docker push "${IMAGE}"

echo "==> [3/4] Applying manifests..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/webapp/serviceaccount.yaml
kubectl apply -f k8s/webapp/configmap.yaml   # uses cluster-internal Conjur URL

echo "==> [4/4] Deploying MySQL and webapp..."
kubectl apply -f k8s/mysql/statefulset.yaml

# Generate Flask secret key
kubectl -n securetask get secret flask-secret &>/dev/null || \
  kubectl -n securetask create secret generic flask-secret \
    --from-literal=secret-key="$(openssl rand -hex 32)"

sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" k8s/webapp/deployment.yaml | kubectl apply -f -

kubectl -n securetask rollout status deployment/webapp --timeout=5m

echo ""
echo "Done! Port-forward to access the app:"
echo "  kubectl -n securetask port-forward svc/webapp 8080:80"
echo "  open http://localhost:8080/app"
