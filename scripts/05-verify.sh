#!/usr/bin/env bash
# 05-verify.sh - Checks all components are healthy.

set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  [OK]  $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "==> Infrastructure"
R="$(kubectl -n conjur get deploy conjur-oss -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${R:-0}" -ge 1 ] && ok "Conjur OSS running" || fail "Conjur OSS not ready"

echo "==> Application"
R="$(kubectl -n securetask get statefulset mysql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${R:-0}" -ge 1 ] && ok "MySQL running" || fail "MySQL not ready"

R="$(kubectl -n securetask get deploy webapp -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${R:-0}" -ge 1 ] && ok "Webapp running" || fail "Webapp not ready"

echo "==> Secrets in Conjur"
kubectl -n conjur port-forward svc/conjur-oss 8444:443 &>/dev/null &
PF=$!; sleep 3; trap "kill ${PF} 2>/dev/null" EXIT

ADMIN_KEY="$(kubectl -n conjur get secret conjur-admin-api-key -o jsonpath='{.data.key}' | base64 -d)"
kubectl -n conjur exec deploy/conjur-oss -c conjur-oss-nginx -- \
  cat /opt/conjur/etc/ssl/cert/tls.crt > /tmp/ca.pem 2>/dev/null || \
  kubectl -n securetask get secret conjur-ssl-cert -o jsonpath='{.data.certificate}' \
    | base64 -d > /tmp/ca.pem

TOKEN="$(printf '%s' "${ADMIN_KEY}" | curl -sSf -k \
  -X POST "https://localhost:8444/authn/myConjurAccount/admin/authenticate" \
  -H 'Accept-Encoding: base64' --data-binary @- | tr -d '\n\r ')"

for var in myapp/database/host myapp/database/user myapp/database/password; do
  ENC="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${var}', safe=''))")"
  VAL="$(curl -sf -k "https://localhost:8444/secrets/myConjurAccount/variable/${ENC}" \
    -H "Authorization: Token token=\"${TOKEN}\"" 2>/dev/null || echo '')"
  [ -n "${VAL}" ] && ok "Conjur: ${var}" || fail "Conjur: ${var} empty"
done

echo "==> App health"
kubectl -n securetask port-forward svc/webapp 18080:80 &>/dev/null &
PF2=$!; trap "kill ${PF} ${PF2} 2>/dev/null" EXIT; sleep 3
CODE="$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18080/healthz)"
[ "${CODE}" = "200" ] && ok "/healthz -> 200" || fail "/healthz -> ${CODE}"

echo ""
echo "=============================="
echo " ${PASS} passed / ${FAIL} failed"
echo "=============================="
[ "${FAIL}" -eq 0 ] && echo " All good! Open: http://localhost:18080/app"
