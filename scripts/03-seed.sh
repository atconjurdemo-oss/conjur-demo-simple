#!/usr/bin/env bash
# 03-seed.sh
# Loads Conjur policies and writes secrets.
# Requires: conjur CLI installed and DOMAIN set.
#
# Usage:
#   export DOMAIN=myapp.duckdns.org
#   export DB_APP_PASSWORD=<your-password>   # or leave blank to generate
#   bash scripts/03-seed.sh

set -euo pipefail

: "${DOMAIN:?Set DOMAIN}"
ACCOUNT="myConjurAccount"
CONJUR_URL="https://${DOMAIN}"

# Auth
ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d)"
kubectl -n conjur get secret conjur-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/conjur-ca.pem

printf '%s\n' '---' "account: ${ACCOUNT}" \
  "appliance_url: ${CONJUR_URL}" 'cert_file: /tmp/conjur-ca.pem' > ~/.conjurrc

conjur login -i admin -p "${ADMIN_KEY}"
conjur whoami && echo "Authenticated to Conjur"

# Load policies
echo ""
echo "==> Loading policies..."
python3 -c "print('- !policy\n  id: conjur')"    | conjur policy load -b root -f - || true
python3 -c "print('- !policy\n  id: authn-jwt')" | conjur policy load -b conjur -f - || true
conjur policy load -b root           -f conjur-policy/root.yml
conjur policy load -b myapp          -f conjur-policy/database.yml
conjur policy load -b conjur/authn-jwt -f conjur-policy/authn-jwt.yml

# Configure JWT authenticator
echo ""
echo "==> Configuring JWT authenticator..."
OIDC="$(kubectl get --raw /.well-known/openid-configuration)"
ISSUER="$(echo "${OIDC}" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")"
conjur variable set -i conjur/authn-jwt/k8s-cluster/jwks-uri -v "${ISSUER}/jwks"
conjur variable set -i conjur/authn-jwt/k8s-cluster/issuer   -v "${ISSUER}"
conjur variable set -i conjur/authn-jwt/k8s-cluster/audience -v "${ISSUER}"

# Set database secrets
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

# Store TLS cert for the sidecar
kubectl create namespace securetask --dry-run=client -o yaml | kubectl apply -f -
CERT="$(kubectl -n conjur get secret conjur-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)"
kubectl -n securetask delete secret conjur-ssl-cert --ignore-not-found
kubectl -n securetask create secret generic conjur-ssl-cert \
  --from-literal=certificate="${CERT}"

echo ""
echo "==> Verifying..."
for var in myapp/database/host myapp/database/user conjur/authn-jwt/k8s-cluster/issuer; do
  val="$(conjur variable get -i "${var}" 2>/dev/null || echo '')"
  [ -n "${val}" ] && echo "  [OK] ${var}" || echo "  [FAIL] ${var}"
done

echo ""
echo "Done! Next: bash scripts/04-deploy-app.sh"
