#!/usr/bin/env bash
# 08-deploy-monitoring.sh — Deploy Prometheus + Grafana monitoring stack.
# Grafana is accessible at http://<IP>/monitoring after this runs.
#
# Usage:
#   bash scripts/08-deploy-monitoring.sh

set -euo pipefail

echo "==> [1/3] Installing kube-prometheus-stack..."
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts --force-update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

GRAFANA_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)"
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=password="${GRAFANA_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/helm-values.yaml \
  --set grafana.adminPassword="${GRAFANA_PASS}" \
  --set "grafana.grafana\\.ini.server.root_url=http://${EXTERNAL_IP}/monitoring/" \
  --wait --timeout 8m

echo "==> [2/3] Applying dashboard and ServiceMonitor..."
kubectl apply -f k8s/monitoring/grafana-dashboard.yaml  2>/dev/null || true
kubectl apply -f k8s/monitoring/service-monitor.yaml    2>/dev/null || true

echo "==> [3/3] Exposing Grafana via LoadBalancer..."
# Grafana subpath routing causes redirect loops — use direct LoadBalancer instead
kubectl -n monitoring patch svc kube-prometheus-stack-grafana \
  -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n monitoring delete ingress gateway-monitoring --ignore-not-found 2>/dev/null || true

echo "Waiting for Grafana external IP..."
for i in $(seq 1 20); do
  GRAFANA_IP="$(kubectl -n monitoring get svc kube-prometheus-stack-grafana \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${GRAFANA_IP}" ] && break
  sleep 10
done

EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '<pending>')"

echo ""
echo "=============================="
echo " App:          http://${EXTERNAL_IP}/app"
echo " Conjur UI:    http://${EXTERNAL_IP}/ui"
echo " Presentation: http://${EXTERNAL_IP}/presentation"
echo " Grafana:      http://${GRAFANA_IP:-<pending>}"
echo "=============================="
echo ""
echo " Grafana login: admin / ${GRAFANA_PASS}"
echo " (Also stored in: kubectl -n monitoring get secret grafana-admin \\"
echo "   -o jsonpath='{.data.password}' | base64 -d)"
