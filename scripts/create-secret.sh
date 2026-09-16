#!/usr/bin/env bash
# Control Plane/CI step: create the Kubernetes Secret holding the AES-256-GCM
# decryption key and nonce produced by producer/src/select_and_encrypt.py.
#
# The Producer never runs this - it has no cluster credentials or RBAC
# permissions. This script is run by whoever/whatever operates the cluster
# (a human with kubectl access, or a CI job with a scoped kubeconfig).
#
# Usage:
#   ./scripts/create-secret.sh [out-dir] [namespace] [secret-name]
# Defaults:
#   out-dir=out  namespace=confidential-ml-poc  secret-name=model-decryption-key

set -euo pipefail

OUT_DIR="${1:-out}"
NAMESPACE="${2:-confidential-ml-poc}"
SECRET_NAME="${3:-model-decryption-key}"

KEY_FILE="${OUT_DIR}/encryption.key"
NONCE_FILE="${OUT_DIR}/encryption.nonce"

for f in "$KEY_FILE" "$NONCE_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "error: '$f' not found - run producer/src/select_and_encrypt.py first." >&2
    exit 1
  fi
done

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-file="encryption.key=${KEY_FILE}" \
  --from-file="encryption.nonce=${NONCE_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret '$SECRET_NAME' created/updated in namespace '$NAMESPACE'."
