#!/usr/bin/env bash
# Control Plane/CI step: create the Kubernetes ConfigMap holding the
# Ed25519 public key produced by layer2/producer/src/generate_keys.py.
#
# The Producer never runs this - it has no cluster credentials or RBAC
# permissions. This script is run by whoever/whatever operates the cluster
# (a human with kubectl access, or a CI job with a scoped kubeconfig), the
# same as scripts/create-secret.sh.
#
# A ConfigMap (not a Secret) is used because the public key is not secret
# data.
#
# Usage:
#   ./scripts/create-configmap.sh [out-dir] [namespace] [configmap-name]
# Defaults:
#   out-dir=out  namespace=confidential-ml-poc  configmap-name=model-verification-key

set -euo pipefail

OUT_DIR="${1:-out}"
NAMESPACE="${2:-confidential-ml-poc}"
CONFIGMAP_NAME="${3:-model-verification-key}"

PUBLIC_KEY_FILE="${OUT_DIR}/producer_ed25519.pub"

if [[ ! -f "$PUBLIC_KEY_FILE" ]]; then
  echo "error: '$PUBLIC_KEY_FILE' not found - run layer2/producer/src/generate_keys.py first." >&2
  exit 1
fi

kubectl create configmap "$CONFIGMAP_NAME" \
  --namespace "$NAMESPACE" \
  --from-file="producer_ed25519.pub=${PUBLIC_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ConfigMap '$CONFIGMAP_NAME' created/updated in namespace '$NAMESPACE'."
