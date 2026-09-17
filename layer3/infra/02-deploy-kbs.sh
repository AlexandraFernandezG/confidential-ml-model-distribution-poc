#!/usr/bin/env bash
# Layer 3: deploy the Trustee Key Broker Service (KBS) in dev/test mode,
# on the same cluster as CoCo, exposed via NodePort.
#
# This is explicitly the dev/test Trustee deployment (no TLS, no HSM, a
# self-signed/auto-generated KBS key pair) - it is NOT a production
# deployment. See the Layer 3 README for what a production KBS setup would
# need instead (real attestation policy, TLS, HA, etc.).
#
# Version pin: Trustee v0.10.1 (a small patch release on top of the
# v0.10.0 the tutorial uses - see 01-install-coco-operator.sh for why the
# operator itself stays on v0.10.0). A newer Trustee version could be
# substituted later by changing TRUSTEE_VERSION below.
#
# Usage:
#   ./layer3/infra/02-deploy-kbs.sh [out-dir]
# Defaults: out-dir=out
#
# Writes KBS_HOST/KBS_PORT to <out-dir>/kbs-endpoint.env for later steps
# (03-fetch-kbs-client.sh, 04-set-resource.sh, 05-set-resource-policy.sh)
# to source.

set -euo pipefail

TRUSTEE_VERSION="v0.10.1"
NAMESPACE="coco-tenant"

OUT_DIR="${1:-out}"
TRUSTEE_SRC="${OUT_DIR}/trustee-src"

if [[ -d "${TRUSTEE_SRC}/.git" ]]; then
  echo "Trustee source already present at '${TRUSTEE_SRC}' (skipping clone)."
else
  echo "Cloning trustee @ ${TRUSTEE_VERSION}..."
  git clone --depth 1 --branch "$TRUSTEE_VERSION" \
    https://github.com/confidential-containers/trustee.git "$TRUSTEE_SRC"
fi

echo "Deploying KBS (dev/test mode, NodePort) into namespace '${NAMESPACE}'..."
(
  cd "${TRUSTEE_SRC}/kbs/config/kubernetes"
  DEPLOYMENT_DIR=nodeport ./deploy-kbs.sh
)

echo "Waiting for the kbs deployment to become ready..."
kubectl rollout status deployment/kbs -n "$NAMESPACE" --timeout=300s

# Filter explicitly for InternalIP rather than taking addresses[0] - node
# address ordering isn't guaranteed, and a Hostname-type entry (e.g. an
# EC2 instance's "ip-10-0-1-23.ec2.internal") may not be resolvable from
# wherever kbs-client or the pod's Kata guest agent run.
KBS_HOST="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
KBS_PORT="$(kubectl get svc kbs -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')"

if [[ -z "$KBS_HOST" || -z "$KBS_PORT" ]]; then
  echo "error: could not determine KBS_HOST/KBS_PORT from the cluster." >&2
  echo "Check manually: kubectl get nodes -o wide; kubectl get svc kbs -n ${NAMESPACE}" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
ENV_FILE="${OUT_DIR}/kbs-endpoint.env"
cat > "$ENV_FILE" <<EOF
KBS_HOST=${KBS_HOST}
KBS_PORT=${KBS_PORT}
EOF

echo
echo "KBS is up at ${KBS_HOST}:${KBS_PORT}"
echo "Written to '${ENV_FILE}' - source it in later steps: source ${ENV_FILE}"
