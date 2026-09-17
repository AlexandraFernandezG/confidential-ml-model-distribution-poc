#!/usr/bin/env bash
# Layer 2 demo: prove the consumer aborts BEFORE decrypting when the
# encrypted artifact has been tampered with after signing.
#
# Prerequisites: the full Layer 1 + Layer 2 producer pipeline has already
# been run once for --repo-id (select_and_encrypt.py, push_artifact.py,
# generate_keys.py, sign_artifact.py), so a valid model.tar.enc and
# model.tar.enc.sig exist on the Hub, and out/producer_ed25519.pub exists
# locally to act as the verification key (playing the role the ConfigMap
# plays inside the cluster).
#
# Usage:
#   ./layer2/scripts/demo-tamper.sh <repo-id> [out-dir]
# Example:
#   ./layer2/scripts/demo-tamper.sh your-hf-username/bert-tiny-encrypted

set -euo pipefail

REPO_ID="${1:?usage: demo-tamper.sh <repo-id> [out-dir]}"
OUT_DIR="${2:-out}"
DEMO_DIR="${OUT_DIR}/tamper-demo"

PUBLIC_KEY="${OUT_DIR}/producer_ed25519.pub"
if [[ ! -f "$PUBLIC_KEY" ]]; then
  echo "error: '$PUBLIC_KEY' not found - run layer2/producer/src/generate_keys.py first." >&2
  exit 1
fi

rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"

echo "== Step 1: fetch the real artifact and verify it (expected: PASS) =="
python consumer/src/fetch_artifact.py --repo-id "$REPO_ID" --out-dir "$DEMO_DIR"
python layer2/consumer/src/verify_signature.py \
  --repo-id "$REPO_ID" \
  --artifact-path "$DEMO_DIR/model.tar.enc" \
  --public-key-path "$PUBLIC_KEY" \
  --out-dir "$DEMO_DIR"
echo "PASS confirmed."
echo

echo "== Step 2: corrupt the local copy of the artifact =="
python - "$DEMO_DIR/model.tar.enc" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as f:
    byte = f.read(1)
    f.seek(0)
    f.write(bytes([byte[0] ^ 0xFF]))
print(f"Flipped the first byte of {path}")
PY
echo

echo "== Step 3: re-verify the corrupted artifact (expected: ABORT, non-zero exit) =="
set +e
python layer2/consumer/src/verify_signature.py \
  --repo-id "$REPO_ID" \
  --artifact-path "$DEMO_DIR/model.tar.enc" \
  --public-key-path "$PUBLIC_KEY" \
  --out-dir "$DEMO_DIR"
EXIT_CODE=$?
set -e

if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "UNEXPECTED: verification succeeded on a tampered artifact." >&2
  exit 1
fi

echo
echo "Confirmed: verification aborted on the tampered artifact (exit code $EXIT_CODE) - decrypt.py never ran."
