#!/usr/bin/env bash
# 02-init-account.sh
# Initializes the Conjur account and stores admin key + TLS cert.
# Run ONCE after 01-install-conjur.sh.

set -euo pipefail

ACCOUNT="myConjurAccount"

POD="$(kubectl -n conjur get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}')"
echo "Conjur pod: ${POD}"

# Create account
OUTPUT="$(kubectl -n conjur exec "${POD}" -c conjur-oss -- \
  conjurctl account create "${ACCOUNT}" 2>&1)"
echo "${OUTPUT}"

# Store admin key
ADMIN_KEY="$(kubectl -n conjur exec "${POD}" -c conjur-oss -- \
  conjurctl role retrieve-key "${ACCOUNT}:user:admin" | tr -d '[:space:]')"
[ "${#ADMIN_KEY}" -gt 10 ] || { echo "ERROR: could not get admin key"; exit 1; }

kubectl -n conjur create secret generic conjur-admin-api-key \
  --from-literal=key="${ADMIN_KEY}" --dry-run=client -o yaml | kubectl apply -f -
echo "Admin key stored."

# Store TLS cert for the sidecar (self-signed)
kubectl create namespace securetask --dry-run=client -o yaml | kubectl apply -f -
CERT="$(kubectl -n conjur exec "${POD}" -c conjur-oss-nginx -- \
  cat /opt/conjur/etc/ssl/cert/tls.crt 2>/dev/null || echo '')"

if [ -n "${CERT}" ]; then
  kubectl -n securetask delete secret conjur-ssl-cert --ignore-not-found
  kubectl -n securetask create secret generic conjur-ssl-cert \
    --from-literal=certificate="${CERT}"
  echo "conjur-ssl-cert stored."
fi

echo ""
echo "Next: bash scripts/03-seed.sh"
