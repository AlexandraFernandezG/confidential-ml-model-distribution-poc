#!/usr/bin/env bash
# Layer 3: fetch the kbs-client CLI binary via ORAS, as used by the CoCo
# "without confidential hardware" tutorial
# (https://confidentialcontainers.org/blog/2024/12/03/confidential-containers-without-confidential-hardware/).
#
# kbs-client isn't published as a normal versioned GitHub release binary;
# the tutorial instead pulls a specific "sample_only" OCI-artifact build
# from ghcr.io by its content-addressed tag. That tag is independent of
# the Trustee git tag (v0.10.1) used elsewhere in Layer 3 - it's the exact
# reference the tutorial itself pins, kept here for reproducibility. If it
# ever becomes unavailable, check the tutorial link above for a current
# one, or build kbs-client from the trustee-src checkout instead:
#   cd out/trustee-src && cargo build --release --bin kbs-client -p kbs-client
#
# Usage:
#   ./layer3/infra/03-fetch-kbs-client.sh [out-dir]
# Defaults: out-dir=out
# Writes the binary to <out-dir>/bin/kbs-client (and, if not already on
# PATH, a pinned 'oras' CLI to <out-dir>/bin/oras).

set -euo pipefail

ORAS_VERSION="1.3.4"
KBS_CLIENT_REF="ghcr.io/confidential-containers/staged-images/kbs-client:sample_only-x86_64-linux-gnu-68607d4300dda5a8ae948e2562fd06d09cbd7eca"

OUT_DIR="${1:-out}"
BIN_DIR="${OUT_DIR}/bin"
mkdir -p "$BIN_DIR"

if command -v oras >/dev/null 2>&1; then
  ORAS="oras"
elif [[ -x "${BIN_DIR}/oras" ]]; then
  ORAS="${BIN_DIR}/oras"
else
  echo "Fetching oras v${ORAS_VERSION}..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) ORAS_ARCH="amd64" ;;
    aarch64) ORAS_ARCH="arm64" ;;
    *) echo "error: unsupported architecture '$ARCH' for oras auto-fetch - install oras manually and re-run." >&2; exit 1 ;;
  esac
  TARBALL="oras_${ORAS_VERSION}_linux_${ORAS_ARCH}.tar.gz"
  curl -fsSL -o "${BIN_DIR}/${TARBALL}" \
    "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${TARBALL}"
  tar -xzf "${BIN_DIR}/${TARBALL}" -C "$BIN_DIR" oras
  rm -f "${BIN_DIR}/${TARBALL}"
  chmod +x "${BIN_DIR}/oras"
  ORAS="${BIN_DIR}/oras"
fi

# Resolve ORAS to an absolute path before the cd below, so a relative
# path (e.g. out/bin/oras) doesn't get mis-resolved against the new cwd.
case "$ORAS" in
  /*) : ;;
  */*) ORAS="$(cd "$(dirname "$ORAS")" && pwd)/$(basename "$ORAS")" ;;
  *) ORAS="$(command -v "$ORAS")" ;;
esac

echo "Pulling kbs-client via ORAS from ${KBS_CLIENT_REF}..."
(
  cd "$BIN_DIR"
  "$ORAS" pull "$KBS_CLIENT_REF"
)

if [[ ! -f "${BIN_DIR}/kbs-client" ]]; then
  echo "error: expected '${BIN_DIR}/kbs-client' after oras pull, but it wasn't found." >&2
  echo "The pulled artifact's file name may differ - check '${BIN_DIR}' contents." >&2
  exit 1
fi

chmod +x "${BIN_DIR}/kbs-client"
echo "kbs-client installed at '${BIN_DIR}/kbs-client'."
