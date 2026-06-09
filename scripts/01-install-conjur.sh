#!/usr/bin/env bash
# 01-install-conjur.sh
# Installs NGINX Ingress, cert-manager, and Conjur OSS on GKE.
#
# Usage:
#   export DOMAIN=myapp.duckdns.org
#   export DUCKDNS_TOKEN=<your-token>
#   export EMAIL=<your-email>
#   bash scripts/01-install-conjur.sh

set -euo pipefail

: "${DOMAIN:?Set DOMAIN e.g. myapp.duckdns.org}"
: "${DUCKDNS_TOKEN:?Set DUCKDNS_TOKEN}"
: "${EMAIL:?Set EMAIL for Let's Encrypt}"

SUBDOMAIN="${DOMAIN%%.*}"

echo "==> [1/6] Installing NGINX Ingress..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 3m

echo "==> [2/6] Getting external IP and updating DNS..."
for i in $(seq 1 30); do
  IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${IP}" ] && break; sleep 10
done
[ -z "${IP}" ] && { echo "ERROR: no external IP"; exit 1; }

curl -fsSL "https://www.duckdns.org/update?domains=${SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${IP}" | grep -q OK
echo "DNS: ${DOMAIN} -> ${IP}"

echo "==> [3/6] Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=3m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=3m
sleep 15

echo "==> [4/6] Creating ClusterIssuer..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

echo "==> [5/6] Installing Conjur OSS..."
kubectl create namespace conjur --dry-run=client -o yaml | kubectl apply -f -
DATA_KEY="$(openssl rand -base64 32)"
kubectl -n conjur create secret generic conjur-data-key \
  --from-literal=key="${DATA_KEY}" --dry-run=client -o yaml | kubectl apply -f -

helm repo add cyberark https://cyberark.github.io/helm-charts --force-update
cat > /tmp/conjur-values.yaml <<EOF
account:
  name: myConjurAccount
authenticators: "authn,authn-jwt/k8s-cluster"
ssl:
  hostname: "${DOMAIN}"
service:
  type: ClusterIP
dataKey: "$(echo "${DATA_KEY}" | tr -d '\n')"
EOF

helm upgrade --install conjur-oss cyberark/conjur-oss \
  --namespace conjur --values /tmp/conjur-values.yaml --wait --timeout 5m
rm /tmp/conjur-values.yaml

# Patch authenticators secret
ENCODED="$(echo -n 'authn,authn-jwt/k8s-cluster' | base64 | tr -d '\n')"
kubectl -n conjur patch secret conjur-oss-conjur-authenticators \
  -p "{\"data\":{\"key\":\"${ENCODED}\"}}"
kubectl -n conjur rollout restart deployment/conjur-oss
kubectl -n conjur rollout status deployment/conjur-oss --timeout=3m

echo "==> [6/6] Creating Ingress and TLS cert..."
kubectl apply -f k8s/conjur/ingress.yaml

kubectl -n conjur get ingress conjur -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); \
    d['spec']['rules'][0]['host']='${DOMAIN}'; \
    d['spec']['tls'][0]['hosts'][0]='${DOMAIN}'; \
    print(json.dumps(d))" | kubectl apply -f -

echo ""
echo "Waiting for TLS cert (up to 5 min)..."
kubectl wait certificate/conjur-tls -n conjur --for=condition=Ready --timeout=5m
echo "Done! Conjur: https://${DOMAIN}"
echo ""
echo "Next: bash scripts/02-init-account.sh"
