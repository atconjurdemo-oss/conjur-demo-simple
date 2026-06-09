#!/usr/bin/env bash
# 03-seed.sh
# Loads Conjur policies and writes secrets.
#
# Usage:
#   export DB_APP_PASSWORD=MySecurePass123
#   bash scripts/03-seed.sh

set -euo pipefail

ACCOUNT="myConjurAccount"
CONJUR_URL="https://conjur-oss.conjur.svc.cluster.local"

# Auth via port-forward (Conjur is cluster-internal)
echo "==> Setting up port-forward to Conjur..."
kubectl -n conjur port-forward svc/conjur-oss 8443:443 &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null" EXIT

ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d)"

# Extract cert for CLI
kubectl -n conjur exec deploy/conjur-oss -c conjur-oss-nginx -- \
  cat /opt/conjur/etc/ssl/cert/tls.crt > /tmp/conjur-ca.pem 2>/dev/null || \
  kubectl -n securetask get secret conjur-ssl-cert \
    -o jsonpath='{.data.certificate}' | base64 -d > /tmp/conjur-ca.pem

printf '%s\n' '---' "account: ${ACCOUNT}" \
  "appliance_url: https://localhost:8443" \
  'cert_file: /tmp/conjur-ca.pem' > ~/.conjurrc

conjur login -i admin -p "${ADMIN_KEY}"
conjur whoami && echo "Authenticated"

echo ""
echo "==> Loading policies..."
python3 -c "print('- !policy\n  id: conjur')"    | conjur policy load -b root -f - || true
python3 -c "print('- !policy\n  id: authn-jwt')" | conjur policy load -b conjur -f - || true
conjur policy load -b root           -f conjur-policy/root.yml
conjur policy load -b myapp          -f conjur-policy/database.yml
conjur policy load -b conjur/authn-jwt -f conjur-policy/authn-jwt.yml

echo ""
echo "==> Configuring JWT authenticator..."
OIDC="$(kubectl get --raw /.well-known/openid-configuration)"
ISSUER="$(echo "${OIDC}" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")"
conjur variable set -i conjur/authn-jwt/k8s-cluster/jwks-uri -v "${ISSUER}/jwks"
conjur variable set -i conjur/authn-jwt/k8s-cluster/issuer   -v "${ISSUER}"
conjur variable set -i conjur/authn-jwt/k8s-cluster/audience -v "${ISSUER}"

echo ""
echo "==> Writing database secrets..."
EXISTING_ROOT="$(conjur variable get -i myapp/database/root-password 2>/dev/null || echo '')"
DB_ROOT="${EXISTING_ROOT:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}"
DB_APP="${DB_APP_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}"

conjur variable set -i myapp/database/host          -v "mysql.securetask.svc.cluster.local"
conjur variable set -i myapp/database/port          -v "3306"
conjur variable set -i myapp/database/user          -v "appuser"
conjur variable set -i myapp/database/password      -v "${DB_APP}"
conjur variable set -i myapp/database/name          -v "securetask"
conjur variable set -i myapp/database/root-password -v "${DB_ROOT}"

echo ""
echo "==> Verifying..."
for var in myapp/database/host myapp/database/user conjur/authn-jwt/k8s-cluster/issuer; do
  val="$(conjur variable get -i "${var}" 2>/dev/null || echo '')"
  [ -n "${val}" ] && echo "  [OK] ${var}" || echo "  [FAIL] ${var}"
done

echo ""
echo "Done! Next: bash scripts/04-deploy-app.sh"
