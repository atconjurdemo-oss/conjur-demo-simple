#!/usr/bin/env bash
# 01-install-conjur.sh — Install NGINX Ingress and Conjur OSS on GKE.
#
# Prerequisites: kubectl, helm
# Usage:
#   bash scripts/01-install-conjur.sh

set -euo pipefail

echo "==> [1/3] Installing NGINX Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 3m

echo "==> [2/3] Installing Conjur OSS..."
kubectl create namespace conjur --dry-run=client -o yaml | kubectl apply -f -

DATA_KEY="$(openssl rand -base64 32)"
kubectl -n conjur create secret generic conjur-data-key \
  --from-literal=key="${DATA_KEY}" --dry-run=client -o yaml | kubectl apply -f -

helm repo add cyberark https://cyberark.github.io/helm-charts --force-update

cat > /tmp/conjur-helm-values.yaml <<EOF
account:
  name: myConjurAccount
authenticators: "authn,authn-jwt/k8s-cluster"
ssl:
  hostname: conjur-oss.conjur.svc.cluster.local
service:
  type: ClusterIP
dataKey: "$(echo "${DATA_KEY}" | tr -d '\n')"
EOF

helm upgrade --install conjur-oss cyberark/conjur-oss \
  --namespace conjur \
  --values /tmp/conjur-helm-values.yaml \
  --wait --timeout 5m
rm /tmp/conjur-helm-values.yaml

# Enable JWT authenticator
ENCODED="$(echo -n 'authn,authn-jwt/k8s-cluster' | base64 | tr -d '\n')"
kubectl -n conjur patch secret conjur-oss-conjur-authenticators \
  -p "{\"data\":{\"key\":\"${ENCODED}\"}}"
kubectl -n conjur rollout restart deployment/conjur-oss
kubectl -n conjur rollout status deployment/conjur-oss --timeout=3m

echo "==> [3/3] Storing TLS cert for sidecar..."
kubectl create namespace securetask --dry-run=client -o yaml | kubectl apply -f -
CERT="$(kubectl -n conjur exec deploy/conjur-oss -c conjur-oss-nginx -- \
  cat /opt/conjur/etc/ssl/cert/tls.crt 2>/dev/null || echo '')"
if [ -n "${CERT}" ]; then
  kubectl -n securetask delete secret conjur-ssl-cert --ignore-not-found
  kubectl -n securetask create secret generic conjur-ssl-cert \
    --from-literal=certificate="${CERT}"
fi

echo ""
echo "Done! Conjur is running (cluster-internal only)."
echo "Next: bash scripts/02-init-account.sh"
