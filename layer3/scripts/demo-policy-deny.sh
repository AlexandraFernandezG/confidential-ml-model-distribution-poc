#!/usr/bin/env bash
# Layer 3 demo: prove the consumer aborts BEFORE decrypting when KBS's
# resource policy denies key release - the Layer 3 counterpart to
# layer2/scripts/demo-tamper.sh.
#
# Unlike the Layer 2 demo, this cannot run purely locally: fetch_key_kbs.py
# talks to the Confidential Data Hub at 127.0.0.1:8006, which is only
# reachable from INSIDE the consumer pod's confidential VM. This script
# therefore redeploys the real pod against your live cluster.
#
# Prerequisites (run from the repo root):
#   - The full normal Layer 3 flow already works: layer3/infra/01-05 have
#     run, and layer3/k8s/pod-consumer.yaml has its placeholders filled in
#     (<your-registry>, <KBS_HOST>/<KBS_PORT>, HF_REPO_ID) and deploys
#     successfully on its own.
#   - kubectl context points at that cluster.
#
# Usage:
#   ./layer3/scripts/demo-policy-deny.sh [namespace] [out-dir]
# Defaults: namespace=confidential-ml-poc  out-dir=out
#
# Restores the permissive resource-policy.rego on exit, whether the demo
# succeeds or not, so the cluster is left in its normal working state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../infra" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${1:-confidential-ml-poc}"
OUT_DIR="${2:-out}"

KBS_CLIENT="${OUT_DIR}/bin/kbs-client"
AUTH_KEY="${OUT_DIR}/trustee-src/kbs/config/kubernetes/base/kbs.key"
ENV_FILE="${OUT_DIR}/kbs-endpoint.env"
POD_MANIFEST="${REPO_ROOT}/layer3/k8s/pod-consumer.yaml"

require() {
  local f="$1" hint="$2"
  if [[ ! -f "$f" ]]; then
    echo "error: '$f' not found - $hint" >&2
    exit 1
  fi
}

require "$KBS_CLIENT" "run layer3/infra/03-fetch-kbs-client.sh first."
require "$AUTH_KEY" "run layer3/infra/02-deploy-kbs.sh first."
require "$ENV_FILE" "run layer3/infra/02-deploy-kbs.sh first."
require "$POD_MANIFEST" "layer3/k8s/pod-consumer.yaml should ship with the repo."

# shellcheck disable=SC1090
source "$ENV_FILE"

restore_policy() {
  echo
  echo "Restoring the permissive resource policy (cleanup)..."
  "$KBS_CLIENT" --url "http://${KBS_HOST}:${KBS_PORT}" \
    config --auth-private-key "$AUTH_KEY" \
    set-resource-policy --policy-file "${INFRA_DIR}/resource-policy.rego" \
    || echo "warning: failed to restore resource-policy.rego - run layer3/infra/05-set-resource-policy.sh manually." >&2
}
trap restore_policy EXIT

echo "== Step 1: push deny-all-policy.rego (expect: key release will fail) =="
"$KBS_CLIENT" --url "http://${KBS_HOST}:${KBS_PORT}" \
  config --auth-private-key "$AUTH_KEY" \
  set-resource-policy --policy-file "${INFRA_DIR}/deny-all-policy.rego"
echo

echo "== Step 2: (re)deploy the consumer pod =="
kubectl delete pod consumer -n "$NAMESPACE" --ignore-not-found
kubectl apply -f "$POD_MANIFEST"
echo

echo "== Step 3: wait for the pod to reach a terminal state (expect: Failed) =="
kubectl wait pod/consumer -n "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Failed --timeout=180s \
  || true  # fall through to the log/exit-code checks below regardless

echo
echo "== Step 4: inspect logs and exit code =="
LOGS="$(kubectl logs pod/consumer -n "$NAMESPACE" 2>&1 || true)"
echo "$LOGS"

EXIT_CODE="$(kubectl get pod consumer -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")"

if ! echo "$LOGS" | grep -q "KEY RELEASE FAILED"; then
  echo "UNEXPECTED: 'KEY RELEASE FAILED' not found in pod logs." >&2
  exit 1
fi

if [[ -z "$EXIT_CODE" || "$EXIT_CODE" -eq 0 ]]; then
  echo "UNEXPECTED: consumer container did not exit non-zero (exit code: '${EXIT_CODE}')." >&2
  exit 1
fi

echo
echo "Confirmed: KBS denied key release under the deny-all policy, fetch_key_kbs.py"
echo "printed 'KEY RELEASE FAILED', and the consumer container exited non-zero"
echo "(exit code ${EXIT_CODE}) - decrypt.py never ran."
