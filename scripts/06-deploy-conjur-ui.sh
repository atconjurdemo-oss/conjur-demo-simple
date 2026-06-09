#!/usr/bin/env bash
# 06-deploy-conjur-ui.sh
# Builds and deploys the Conjur UI — a Flask dashboard showing
# policies, variables, and audit logs from Conjur OSS.
#
# Usage:
#   export PROJECT_ID=<gcp-project>
#   export REGION=europe-west1
#   bash scripts/06-deploy-conjur-ui.sh

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
REGION="${REGION:-europe-west1}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/conjur-demo"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)"
IMAGE="${REGISTRY}/conjur-ui:${TAG}"
UI_SOURCE="conjur-ui"

[ -d "${UI_SOURCE}" ] || { echo "ERROR: conjur-ui/ directory not found in repo root."; exit 1; }

echo "==> [1/4] Building Conjur UI image..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
gcloud artifacts repositories create conjur-demo \
  --repository-format=docker --location="${REGION}" 2>/dev/null || true

if command -v docker &>/dev/null; then
  docker build -t "${IMAGE}" "${UI_SOURCE}"
  docker push "${IMAGE}"
else
  gcloud builds submit "${UI_SOURCE}" --tag "${IMAGE}" --project "${PROJECT_ID}"
fi

echo "==> [2/4] Adding conjur-ui host to Conjur policy..."
# Port-forward to Conjur for policy update
kubectl -n conjur port-forward svc/conjur-oss 8445:443 &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null" EXIT

ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d)"
TOKEN="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
  -X POST "https://localhost:8445/authn/myConjurAccount/admin/authenticate" \
  -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"

# Add conjur-ui host to policy (can authenticate via JWT)
curl -sk -X POST "https://localhost:8445/policies/myConjurAccount/policy/myapp" \
  -H "Authorization: Token token=\"${TOKEN}\"" \
  -H "Content-Type: application/x-yaml" \
  -d '- !host
  id: conjur-ui
  annotations:
    authn-jwt/k8s-cluster/kubernetes.io/namespace: conjur
    authn-jwt/k8s-cluster/kubernetes.io/serviceaccount/name: conjur-ui' \
  && echo "conjur-ui host added"

# Grant authenticate permission
curl -sk -X POST "https://localhost:8445/policies/myConjurAccount/policy/conjur/authn-jwt" \
  -H "Authorization: Token token=\"${TOKEN}\"" \
  -H "Content-Type: application/x-yaml" \
  -d '- !policy
  id: k8s-cluster
  body:
    - !permit
      role: !host /myapp/conjur-ui
      privilege: [authenticate]
      resource: !webservice' \
  && echo "authenticate grant added"

kill ${PF_PID} 2>/dev/null || true

echo "==> [3/4] Deploying Conjur UI..."
FLASK_KEY="$(openssl rand -hex 32)"
EXTERNAL_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

# ServiceAccount
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: conjur-ui
  namespace: conjur
automountServiceAccountToken: true
EOF

# ConfigMap
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: conjur-ui-config
  namespace: conjur
data:
  CONJUR_APPLIANCE_URL: "https://conjur-oss.conjur.svc.cluster.local"
  CONJUR_ACCOUNT: "myConjurAccount"
  CONJUR_INTERNAL_URL: "https://conjur-oss.conjur.svc.cluster.local"
  CONJUR_INTERNAL_VERIFY: "false"
  CONJUR_SSL_VERIFY: "false"
  CONJUR_AUTHN_JWT_SERVICE: "k8s-cluster"
  CONJUR_HOST_ID: "host/myapp/conjur-ui"
  APPLICATION_ROOT: "/"
EOF

# Secret
kubectl -n conjur create secret generic conjur-ui-secret \
  --from-literal=FLASK_SECRET_KEY="${FLASK_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conjur-ui
  namespace: conjur
  labels:
    app: conjur-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: conjur-ui
  template:
    metadata:
      labels:
        app: conjur-ui
    spec:
      serviceAccountName: conjur-ui
      automountServiceAccountToken: true
      containers:
        - name: conjur-ui
          image: ${IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: conjur-ui-config
            - secretRef:
                name: conjur-ui-secret
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: conjur-ui
  namespace: conjur
spec:
  selector:
    app: conjur-ui
  ports:
    - port: 80
      targetPort: 8080
  type: LoadBalancer
EOF

# Remove old ingress if exists
kubectl -n conjur delete ingress conjur-ui --ignore-not-found

echo "==> [4/4] Waiting for external IP..."
kubectl -n conjur rollout status deployment/conjur-ui --timeout=3m

for i in $(seq 1 20); do
  UI_IP="$(kubectl -n conjur get svc conjur-ui \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${UI_IP}" ] && break
  sleep 10
done

echo ""
echo "Done!"
echo "  Conjur UI:     http://${UI_IP}"
echo "  Incident App:  http://${EXTERNAL_IP}/app"
echo ""
echo "Login to Conjur UI with:"
echo "  Account:  myConjurAccount"
echo "  Username: admin"
echo "  Password: $(kubectl -n conjur get secret conjur-admin-api-key \
    -o jsonpath='{.data.key}' | base64 -d)"
