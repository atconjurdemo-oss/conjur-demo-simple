#!/usr/bin/env bash
# 06-deploy-conjur-ui.sh — Build and deploy the Conjur UI dashboard.
#
# Shows policies, variables, and live Conjur audit logs.
#
# Usage:
#   export PROJECT_ID=<gcp-project>
#   export REGION=europe-west1   # optional
#   bash scripts/06-deploy-conjur-ui.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
REGION="${REGION:-europe-west1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/conjur-demo"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)"
IMAGE="${REGISTRY}/conjur-ui:${TAG}"
PORT=8445

echo "==> [1/4] Building and pushing Conjur UI image (${TAG})..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
gcloud artifacts repositories create conjur-demo \
  --repository-format=docker --location="${REGION}" 2>/dev/null || true

if command -v docker &>/dev/null; then
  docker build -t "${IMAGE}" conjur-ui/
  docker push "${IMAGE}"
else
  gcloud builds submit conjur-ui/ --tag "${IMAGE}" --project "${PROJECT_ID}"
fi

echo "==> [2/4] Granting conjur-ui host permissions in Conjur..."
kubectl -n conjur port-forward svc/conjur-oss ${PORT}:443 &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null" EXIT

ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d)"

_token() {
  printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
    -X POST "https://localhost:${PORT}/authn/myConjurAccount/admin/authenticate" \
    -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r '
}

_policy() {
  local method="$1" branch="$2" data="$3"
  local tok; tok="$(_token)"
  curl -sk -o /dev/null -w "  ${method} ${branch}: HTTP %{http_code}\n" \
    -X "${method}" "https://localhost:${PORT}/policies/myConjurAccount/policy/${branch}" \
    -H "Authorization: Token token=\"${tok}\"" \
    -H "Content-Type: application/x-yaml" \
    --data-binary "${data}"
}

# Add conjur-ui host (idempotent via POST)
_policy POST myapp "@conjur-policy/database.yml"
_policy POST conjur/authn-jwt "@conjur-policy/authn-jwt.yml"

kill ${PF_PID} 2>/dev/null || true

echo "==> [3/4] Deploying Conjur UI..."
kubectl apply -f k8s/conjur-ui/serviceaccount.yaml
kubectl apply -f k8s/conjur-ui/configmap.yaml

# Generate Flask secret key
kubectl -n conjur create secret generic conjur-ui-secret \
  --from-literal=FLASK_SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" k8s/conjur-ui/deployment.yaml | kubectl apply -f -

echo "==> [4/4] Waiting for rollout..."
kubectl -n conjur rollout status deployment/conjur-ui --timeout=3m

echo "Waiting for external IP..."
for i in $(seq 1 20); do
  UI_IP="$(kubectl -n conjur get svc conjur-ui \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${UI_IP}" ] && break
  sleep 10
done

APP_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<pending>')"

echo ""
echo "=============================="
echo " Incident Tracker: http://${APP_IP}/app"
echo " Conjur UI:        http://${UI_IP:-<pending>}"
echo "=============================="
echo ""
echo " Conjur UI login:"
echo "   Account:  myConjurAccount"
echo "   Username: admin"
echo "   Password: \$(kubectl -n conjur get secret conjur-admin-api-key \\"
echo "               -o jsonpath='{.data.key}' | base64 -d)"
