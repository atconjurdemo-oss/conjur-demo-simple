#!/usr/bin/env bash
# 03-seed.sh — Load Conjur policies and write secrets.
#
# Usage:
#   export DB_APP_PASSWORD=MySecurePass123
#   bash scripts/03-seed.sh

set -euo pipefail

: "${DB_APP_PASSWORD:?Set DB_APP_PASSWORD}"
ACCOUNT="myConjurAccount"
PORT=8443

# ── Port-forward ──────────────────────────────────────────────────────────────
echo "==> Setting up port-forward..."
kubectl -n conjur port-forward svc/conjur-oss ${PORT}:443 &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null" EXIT

ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d)"
echo "Admin key: ${#ADMIN_KEY} chars"

# ── Helpers ───────────────────────────────────────────────────────────────────
_token() {
  printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
    -X POST "https://localhost:${PORT}/authn/${ACCOUNT}/admin/authenticate" \
    -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r '
}

_policy() {
  local method="$1" branch="$2" file="$3"
  local tok; tok="$(_token)"
  HTTP=$(curl -sk -o /tmp/pr.txt -w "%{http_code}" \
    -X "${method}" "https://localhost:${PORT}/policies/${ACCOUNT}/policy/${branch}" \
    -H "Authorization: Token token=\"${tok}\"" \
    -H "Content-Type: application/x-yaml" \
    --data-binary "@${file}")
  echo "  ${method} ${branch}: HTTP ${HTTP}"
}

_set() {
  local id="$1" val="$2"
  local tok enc http
  tok="$(_token)"
  enc="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${id}', safe=''))")"
  http="$(printf '%s' "${val}" | curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "https://localhost:${PORT}/secrets/${ACCOUNT}/variable/${enc}" \
    -H "Authorization: Token token=\"${tok}\"" --data-binary @-)"
  [ "${http}" = "201" ] && echo "  set: ${id}" || echo "  WARN: ${id} HTTP ${http}"
}

_get() {
  local id="$1" tok enc
  tok="$(_token)"
  enc="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${id}', safe=''))")"
  curl -sf -k "https://localhost:${PORT}/secrets/${ACCOUNT}/variable/${enc}" \
    -H "Authorization: Token token=\"${tok}\"" 2>/dev/null || echo ''
}

# ── Load policies ─────────────────────────────────────────────────────────────
echo ""
echo "==> Loading policies..."
python3 -c "print('- !policy\n  id: conjur')"    > /tmp/br-conjur.yml
python3 -c "print('- !policy\n  id: authn-jwt')" > /tmp/br-authn.yml
_policy POST root              /tmp/br-conjur.yml
_policy POST conjur            /tmp/br-authn.yml
_policy POST root              conjur-policy/root.yml
_policy PUT  myapp             conjur-policy/database.yml
_policy POST conjur/authn-jwt  conjur-policy/authn-jwt.yml

# ── Configure JWT authenticator ───────────────────────────────────────────────
echo ""
echo "==> Configuring JWT authenticator..."
OIDC="$(kubectl get --raw /.well-known/openid-configuration)"
ISSUER="$(echo "${OIDC}" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")"
_set "conjur/authn-jwt/k8s-cluster/jwks-uri" "${ISSUER}/jwks"
_set "conjur/authn-jwt/k8s-cluster/issuer"   "${ISSUER}"
_set "conjur/authn-jwt/k8s-cluster/audience" "${ISSUER}"

# ── Write database secrets ────────────────────────────────────────────────────
echo ""
echo "==> Writing database secrets..."
EXISTING_ROOT="$(_get myapp/database/root-password)"
DB_ROOT="${EXISTING_ROOT:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}"

_set "myapp/database/host"          "mysql.securetask.svc.cluster.local"
_set "myapp/database/port"          "3306"
_set "myapp/database/user"          "appuser"
_set "myapp/database/password"      "${DB_APP_PASSWORD}"
_set "myapp/database/name"          "securetask"
_set "myapp/database/root-password" "${DB_ROOT}"

# ── Refresh conjur-ssl-cert ───────────────────────────────────────────────────
CERT="$(kubectl -n conjur exec deploy/conjur-oss -c conjur-oss-nginx -- \
  cat /opt/conjur/etc/ssl/cert/tls.crt 2>/dev/null)"
if [ -n "${CERT}" ]; then
  kubectl -n securetask delete secret conjur-ssl-cert --ignore-not-found
  kubectl -n securetask create secret generic conjur-ssl-cert \
    --from-literal=certificate="${CERT}"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying..."
ALL_OK=true
for var in myapp/database/host myapp/database/user \
           conjur/authn-jwt/k8s-cluster/issuer; do
  val="$(_get "${var}")"
  if [ -n "${val}" ]; then
    echo "  [OK] ${var}"
  else
    echo "  [FAIL] ${var}"
    ALL_OK=false
  fi
done

${ALL_OK} && echo "" && echo "Done! Next: bash scripts/04-deploy-app.sh" || \
  { echo "Some secrets missing — check Conjur logs"; exit 1; }
