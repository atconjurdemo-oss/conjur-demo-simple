#!/usr/bin/env bash
# 02-init-account.sh — Initialize the Conjur account (run ONCE after install).
#
# Usage:
#   bash scripts/02-init-account.sh

set -euo pipefail

ACCOUNT="myConjurAccount"

POD="$(kubectl -n conjur get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}')"
echo "Conjur pod: ${POD}"

OUTPUT="$(kubectl -n conjur exec "${POD}" -c conjur-oss -- \
  conjurctl account create "${ACCOUNT}" 2>&1)"
echo "${OUTPUT}"

ADMIN_KEY="$(kubectl -n conjur exec "${POD}" -c conjur-oss -- \
  conjurctl role retrieve-key "${ACCOUNT}:user:admin" | tr -d '[:space:]')"

[ "${#ADMIN_KEY}" -gt 10 ] || { echo "ERROR: could not retrieve admin key"; exit 1; }

kubectl -n conjur create secret generic conjur-admin-api-key \
  --from-literal=key="${ADMIN_KEY}" --dry-run=client -o yaml | kubectl apply -f -

# Refresh the TLS cert now that the pod is fully initialized
kubectl create namespace securetask --dry-run=client -o yaml | kubectl apply -f -
CERT="$(kubectl -n conjur exec "${POD}" -c conjur-oss-nginx -- \
  cat /opt/conjur/etc/ssl/cert/tls.crt 2>/dev/null || echo '')"
if [ -n "${CERT}" ]; then
  kubectl -n securetask delete secret conjur-ssl-cert --ignore-not-found
  kubectl -n securetask create secret generic conjur-ssl-cert \
    --from-literal=certificate="${CERT}"
fi

echo ""
echo "Admin key stored in: conjur/conjur-admin-api-key"
echo "Next: bash scripts/03-seed.sh"
