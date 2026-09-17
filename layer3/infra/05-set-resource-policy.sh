#!/usr/bin/env bash
# Layer 3: load the permissive sample-TEE resource policy (resource-policy.rego)
# into KBS. After this runs, any caller presenting "sample"-TEE attestation
# evidence (i.e. kata-qemu-coco-dev, since there's no real confidential
# hardware here) can read ANY resource, including default/key/my-model.
# See resource-policy.rego for why this is insecure-by-design and
# PoC/demo-only - never use this policy in production.
#
# Prerequisites: same as 04-set-resource.sh - 02-deploy-kbs.sh (for
# KBS_HOST/KBS_PORT and the KBS admin auth key) and 03-fetch-kbs-client.sh
# (for kbs-client) must have already run.
#
# Usage:
#   ./layer3/infra/05-set-resource-policy.sh [out-dir]
# Defaults: out-dir=out

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-out}"

KBS_CLIENT="${OUT_DIR}/bin/kbs-client"
AUTH_KEY="${OUT_DIR}/trustee-src/kbs/config/kubernetes/base/kbs.key"
ENV_FILE="${OUT_DIR}/kbs-endpoint.env"
POLICY_FILE="${SCRIPT_DIR}/resource-policy.rego"

require() {
  local f="$1" hint="$2"
  if [[ ! -f "$f" ]]; then
    echo "error: '$f' not found - $hint" >&2
    exit 1
  fi
}

require "$KBS_CLIENT" "run 03-fetch-kbs-client.sh first."
require "$AUTH_KEY" "run 02-deploy-kbs.sh first."
require "$ENV_FILE" "run 02-deploy-kbs.sh first."
require "$POLICY_FILE" "this should ship with the repo - check layer3/infra/resource-policy.rego exists."

# shellcheck disable=SC1090
source "$ENV_FILE"

echo "Setting resource policy at http://${KBS_HOST}:${KBS_PORT} from '${POLICY_FILE}'..."
"$KBS_CLIENT" --url "http://${KBS_HOST}:${KBS_PORT}" \
  config --auth-private-key "$AUTH_KEY" \
  set-resource-policy --policy-file "$POLICY_FILE"

echo "Resource policy set. Any caller attesting as TEE type 'sample' can now read any KBS resource."
