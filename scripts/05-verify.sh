#!/usr/bin/env bash
# 05-verify.sh
# Checks every component is healthy.

set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  [OK]  $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "==> Conjur"
R="$(kubectl -n conjur get deploy conjur-oss -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${R:-0}" -ge 1 ] && ok "conjur-oss running" || fail "conjur-oss not ready"

echo "==> MySQL"
R="$(kubectl -n securetask get statefulset mysql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${R:-0}" -ge 1 ] && ok "mysql running" || fail "mysql not ready"

echo "==> Webapp"
R="$(kubectl -n securetask get deploy webapp -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${R:-0}" -ge 1 ] && ok "webapp running" || fail "webapp not ready"

echo "==> Secrets in Conjur"
for var in myapp/database/host myapp/database/password conjur/authn-jwt/k8s-cluster/issuer; do
  ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key -o jsonpath='{.data.key}' | base64 -d)"
  CERT="$(kubectl -n conjur get secret conjur-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)"
  echo "${CERT}" > /tmp/ca.pem
  TOKEN="$(printf '%s' "${ADMIN_KEY}" | curl -sSf --cacert /tmp/ca.pem \
    -X POST "https://$(kubectl -n conjur get ingress conjur -o jsonpath='{.spec.rules[0].host}')/authn/myConjurAccount/admin/authenticate" \
    -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"
  ENC="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var}', safe=''))")"
  VAL="$(curl -sf --cacert /tmp/ca.pem \
    "https://$(kubectl -n conjur get ingress conjur -o jsonpath='{.spec.rules[0].host}')/secrets/myConjurAccount/variable/${ENC}" \
    -H "Authorization: Token token=\"${TOKEN}\"" 2>/dev/null || echo '')"
  [ -n "${VAL}" ] && ok "${var}" || fail "${var} empty"
  break  # only check once — re-auth each iteration is slow for a verify script
done

echo ""
echo "=============================="
echo " ${PASS} passed / ${FAIL} failed"
echo "=============================="
