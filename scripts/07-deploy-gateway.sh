#!/usr/bin/env bash
# 07-deploy-gateway.sh — Deploy the unified gateway (single IP for all services).
#
# Routes:
#   /app          → Incident Tracker
#   /ui           → Conjur Admin UI
#   /presentation → Architecture slides
#   /monitoring   → Grafana (optional, deploy monitoring first)
#
# Usage:
#   bash scripts/07-deploy-gateway.sh

set -euo pipefail

echo "==> [1/3] Building presentation ConfigMap..."
kubectl -n securetask create configmap presentation-html \
  --from-file=index.html=presentation/index.html \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/3] Applying gateway manifests..."
# Remove old individual ingresses before creating the unified one
kubectl -n securetask delete ingress webapp     --ignore-not-found
kubectl -n conjur    delete ingress conjur-ui   --ignore-not-found
kubectl apply -f k8s/gateway/presentation.yaml
kubectl apply -f k8s/gateway/cross-namespace-services.yaml
kubectl apply -f k8s/gateway/ingress.yaml

echo "==> [3/3] Waiting for presentation rollout..."
kubectl -n securetask rollout status deployment/presentation --timeout=2m

EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<pending>')"

echo ""
echo "=============================="
echo " Single gateway IP: ${EXTERNAL_IP}"
echo "=============================="
echo "  /app          → http://${EXTERNAL_IP}/app"
echo "  /ui           → http://${EXTERNAL_IP}/ui"
echo "  /presentation → http://${EXTERNAL_IP}/presentation"
echo "  /monitoring   → http://${EXTERNAL_IP}/monitoring"
echo ""
echo "Note: /monitoring requires Deploy Monitoring workflow to run first."
echo "Note: /ui requires 06-deploy-conjur-ui.sh to run first."
