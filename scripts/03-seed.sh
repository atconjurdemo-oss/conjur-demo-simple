#!/usr/bin/env bash
# 03-seed.sh
# Loads Conjur policies and writes secrets using the REST API directly.
# The Conjur CLI v9 has interactive auth issues with self-signed certs.
#
# Usage:
#   export DB_APP_PASSWORD=MySecurePass123
#   bash scripts/03-seed.sh

set -euo pipefail

ACCOUNT="myConjurAccount"

# Port-forward to reach Conjur
echo "==> Setting up port-forward to Conjur..."
kubectl -n conjur port-forward svc/conjur-oss 8443:443 &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null" EXIT

ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d)"
echo "Admin key length: ${#ADMIN_KEY}"

# Get token (-k = skip TLS verification for self-signed cert)
TOKEN="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
  -X POST "https://localhost:8443/authn/${ACCOUNT}/admin/authenticate" \
  -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"
echo "Token length: ${#TOKEN}"
[ "${#TOKEN}" -lt 10 ] && { echo "ERROR: authentication failed"; exit 1; }

# Helpers
policy_load() {
  local branch="$1" file="$2"
  local tok; tok="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
    -X POST "https://localhost:8443/authn/${ACCOUNT}/admin/authenticate" \
    -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"
  HTTP=$(curl -sk -o /tmp/pr.txt -w "%{http_code}" \
    -X POST "https://localhost:8443/policies/${ACCOUNT}/policy/${branch}" \
    -H "Authorization: Token token=\"${tok}\"" \
    -H "Content-Type: application/x-yaml" \
    --data-binary "@${file}")
  echo "  POST ${branch}: HTTP ${HTTP}"
}

set_var() {
  local id="$1" val="$2"
  local tok enc http
  tok="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
    -X POST "https://localhost:8443/authn/${ACCOUNT}/admin/authenticate" \
    -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"
  enc="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${id}', safe=''))")"
  http="$(printf '%s' "${val}" | curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "https://localhost:8443/secrets/${ACCOUNT}/variable/${enc}" \
    -H "Authorization: Token token=\"${tok}\"" \
    --data-binary @-)"
  [ "${http}" = "201" ] && echo "  set: ${id}" || echo "  WARN: ${id} HTTP ${http}"
}

get_var() {
  local id="$1"
  local tok enc
  tok="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
    -X POST "https://localhost:8443/authn/${ACCOUNT}/admin/authenticate" \
    -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"
  enc="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${id}', safe=''))")"
  curl -sf -k "https://localhost:8443/secrets/${ACCOUNT}/variable/${enc}" \
    -H "Authorization: Token token=\"${tok}\"" 2>/dev/null || echo ''
}

# Create policy branches
echo ""
echo "==> Loading policies..."
python3 -c "print('- !policy\n  id: conjur')"    > /tmp/br-conjur.yml
python3 -c "print('- !policy\n  id: authn-jwt')" > /tmp/br-authn.yml
policy_load root /tmp/br-conjur.yml
policy_load conjur /tmp/br-authn.yml
policy_load root conjur-policy/root.yml
# Use PUT for myapp to always replace permits cleanly
local tok; tok="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
  -X POST "https://localhost:8443/authn/${ACCOUNT}/admin/authenticate" \
  -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"
HTTP=$(curl -sk -o /tmp/pr.txt -w "%{http_code}" \
  -X PUT "https://localhost:8443/policies/${ACCOUNT}/policy/myapp" \
  -H "Authorization: Token token=\"${tok}\"" \
  -H "Content-Type: application/x-yaml" \
  --data-binary "@conjur-policy/database.yml")
echo "  PUT myapp: HTTP ${HTTP}"
policy_load conjur/authn-jwt conjur-policy/authn-jwt.yml

# Configure JWT
echo ""
echo "==> Configuring JWT authenticator..."
OIDC="$(kubectl get --raw /.well-known/openid-configuration)"
ISSUER="$(echo "${OIDC}" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")"
set_var "conjur/authn-jwt/k8s-cluster/jwks-uri" "${ISSUER}/jwks"
set_var "conjur/authn-jwt/k8s-cluster/issuer"   "${ISSUER}"
set_var "conjur/authn-jwt/k8s-cluster/audience"  "${ISSUER}"

# Write secrets
echo ""
echo "==> Writing database secrets..."
EXISTING_ROOT="$(get_var myapp/database/root-password)"
DB_ROOT="${EXISTING_ROOT:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}"
DB_APP="${DB_APP_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}"

set_var "myapp/database/host"          "mysql.securetask.svc.cluster.local"
set_var "myapp/database/port"          "3306"
set_var "myapp/database/user"          "appuser"
set_var "myapp/database/password"      "${DB_APP}"
set_var "myapp/database/name"          "securetask"
set_var "myapp/database/root-password" "${DB_ROOT}"

# Verify
echo ""
echo "==> Verifying..."
for var in myapp/database/host myapp/database/user conjur/authn-jwt/k8s-cluster/issuer; do
  val="$(get_var "${var}")"
  [ -n "${val}" ] && echo "  [OK] ${var}" || echo "  [FAIL] ${var}"
done

echo ""
echo "Done! Next: bash scripts/04-deploy-app.sh"
