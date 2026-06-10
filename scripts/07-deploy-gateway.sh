#!/usr/bin/env bash
# 07-deploy-gateway.sh — Deploy the unified gateway (single IP for all services).
#
# Routes:
#   /app          → Incident Tracker    (always)
#   /presentation → Architecture slides (always)
#   /ui           → Conjur Admin UI     (requires 06-deploy-conjur-ui.sh)
#   /monitoring   → Grafana             (requires monitoring stack)
#
# Usage:
#   bash scripts/07-deploy-gateway.sh

set -euo pipefail

echo "==> [1/3] Building presentation ConfigMap..."
kubectl -n securetask create configmap presentation-html \
  --from-file=index.html=presentation/index.html \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/3] Removing old individual ingresses..."
kubectl -n securetask delete ingress webapp   --ignore-not-found
kubectl -n conjur    delete ingress conjur-ui --ignore-not-found

echo "==> [3/3] Applying gateway ingresses..."
kubectl apply -f k8s/gateway/presentation.yaml
kubectl apply -f k8s/gateway/ingress-securetask.yaml

if kubectl get namespace conjur &>/dev/null; then
  kubectl apply -f k8s/gateway/ingress-conjur.yaml
  echo "  /ui    → conjur-ui applied"
else
  echo "  /ui    → skipped (conjur namespace not found)"
fi

if kubectl get namespace monitoring &>/dev/null; then
  kubectl apply -f k8s/gateway/ingress-monitoring.yaml
  echo "  /monitoring → grafana applied"
else
  echo "  /monitoring → skipped (run monitoring deploy first)"
fi

kubectl -n securetask rollout status deployment/presentation --timeout=2m

EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<pending>')"

echo ""
echo "=============================="
echo " Gateway IP: ${EXTERNAL_IP}"
echo "=============================="
echo "  http://${EXTERNAL_IP}/app"
echo "  http://${EXTERNAL_IP}/presentation"
echo "  http://${EXTERNAL_IP}/ui"
echo "  http://${EXTERNAL_IP}/monitoring"
