#!/usr/bin/env bash
# Layer 3: push the AES-256-GCM decryption key (+ nonce) produced by
# producer/src/select_and_encrypt.py into KBS, under the resource path
# default/key/my-model - the Layer 3 replacement for a Kubernetes Secret
# (compare scripts/create-secret.sh, which does the equivalent for the
# Layer 1 Secret-based flow).
#
# KBS resources are single blobs at one path, but decrypt.py needs both a
# key and a nonce. Both are combined into one JSON object
# ({"key": "<b64>", "nonce": "<b64>"}) stored at that single path;
# layer3/consumer/src/fetch_key_kbs.py (consumer side) parses both back
# out of it.
#
# Prerequisites:
#   - 02-deploy-kbs.sh has run (for KBS_HOST/KBS_PORT and the KBS admin
#     auth key generated at
#     <out-dir>/trustee-src/kbs/config/kubernetes/base/kbs.key)
#   - 03-fetch-kbs-client.sh has run (for <out-dir>/bin/kbs-client)
#   - producer/src/select_and_encrypt.py has produced
#     <out-dir>/encryption.key and <out-dir>/encryption.nonce
#
# Usage:
#   ./layer3/infra/04-set-resource.sh [out-dir] [resource-path]
# Defaults: out-dir=out  resource-path=default/key/my-model

set -euo pipefail

OUT_DIR="${1:-out}"
RESOURCE_PATH="${2:-default/key/my-model}"

KEY_FILE="${OUT_DIR}/encryption.key"
NONCE_FILE="${OUT_DIR}/encryption.nonce"
KBS_CLIENT="${OUT_DIR}/bin/kbs-client"
AUTH_KEY="${OUT_DIR}/trustee-src/kbs/config/kubernetes/base/kbs.key"
ENV_FILE="${OUT_DIR}/kbs-endpoint.env"

require() {
  local f="$1" hint="$2"
  if [[ ! -f "$f" ]]; then
    echo "error: '$f' not found - $hint" >&2
    exit 1
  fi
}

require "$KEY_FILE" "run producer/src/select_and_encrypt.py first."
require "$NONCE_FILE" "run producer/src/select_and_encrypt.py first."
require "$KBS_CLIENT" "run 03-fetch-kbs-client.sh first."
require "$AUTH_KEY" "run 02-deploy-kbs.sh first."
require "$ENV_FILE" "run 02-deploy-kbs.sh first."

# shellcheck disable=SC1090
source "$ENV_FILE"

RESOURCE_FILE="${OUT_DIR}/kbs-resource.json"
python3 - "$KEY_FILE" "$NONCE_FILE" "$RESOURCE_FILE" <<'PY'
import json
import sys

key_path, nonce_path, out_path = sys.argv[1:4]
key = open(key_path).read().strip()
nonce = open(nonce_path).read().strip()
with open(out_path, "w") as f:
    json.dump({"key": key, "nonce": nonce}, f)
PY

echo "Setting KBS resource '${RESOURCE_PATH}' at http://${KBS_HOST}:${KBS_PORT}..."
"$KBS_CLIENT" --url "http://${KBS_HOST}:${KBS_PORT}" \
  config --auth-private-key "$AUTH_KEY" \
  set-resource --path "$RESOURCE_PATH" --resource-file "$RESOURCE_FILE"

echo "Resource '${RESOURCE_PATH}' stored in KBS."
echo "NOTE: '${RESOURCE_FILE}' contains the raw decryption key/nonce in cleartext JSON - do not commit it (already under the gitignored /out/ path)."
