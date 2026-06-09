#!/usr/bin/env bash
# 02-init-account.sh
# Initializes the Conjur account and stores the admin key.
# Run ONCE after 01-install-conjur.sh.

set -euo pipefail

ACCOUNT="myConjurAccount"

POD="$(kubectl -n conjur get pod -l app=conjur-oss -o jsonpath='{.items[0].metadata.name}')"
echo "Conjur pod: ${POD}"

# Create account and store the admin key
OUTPUT="$(kubectl -n conjur exec "${POD}" -c conjur-oss -- \
  conjurctl account create "${ACCOUNT}" 2>&1)"
echo "${OUTPUT}"

ADMIN_KEY="$(kubectl -n conjur exec "${POD}" -c conjur-oss -- \
  conjurctl role retrieve-key "${ACCOUNT}:user:admin" | tr -d '[:space:]')"

[ "${#ADMIN_KEY}" -gt 10 ] || { echo "ERROR: could not retrieve admin key"; exit 1; }

kubectl -n conjur create secret generic conjur-admin-api-key \
  --from-literal=key="${ADMIN_KEY}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Admin key stored in k8s secret: conjur/conjur-admin-api-key"
echo "Next: bash scripts/03-seed.sh"
