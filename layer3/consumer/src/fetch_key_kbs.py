"""
Layer 3 - Consumer step (replaces Layer 1's Secret-mount key loading):
fetch the AES-256-GCM decryption key + nonce from KBS through the
Confidential Data Hub (CDH) endpoint, relying on the pod's remote
attestation having already succeeded (kata-qemu-coco-dev +
agent.aa_kbc_params, configured in k8s/pod-consumer.yaml).

CDH is only reachable at 127.0.0.1:8006 from INSIDE the confidential VM
the pod runs in - the kata-agent proxies it in from the guest, it is not
a regular pod-to-pod or pod-to-host network path. A GET to
http://127.0.0.1:8006/cdh/resource/<resource-path> returns the resource's
raw bytes exactly as stored in KBS (no JSON envelope from CDH itself);
04-set-resource.sh stores a JSON object ({"key": "<b64>", "nonce": "<b64>"})
at that path, since KBS resources are single blobs at one path but
decrypt.py needs both values, so this script unpacks that JSON.

This must run BEFORE decrypt.py, and after Layer 2's verify_signature.py.
If the CDH fetch fails (attestation rejected, policy denies release, CDH
unreachable, malformed resource), the process exits non-zero and
decrypt.py must never run.

decrypt.py itself is unchanged: this script writes the key/nonce out as
the same base64 text files decrypt.py already expects via its
--key-path/--nonce-path flags, just at a different location (no Secret
volume in Layer 3) - the pod command passes those flags explicitly.
"""

import argparse
import base64
import json
import sys
from pathlib import Path

import requests

DEFAULT_RESOURCE_PATH = "default/key/my-model"
DEFAULT_CDH_HOST = "127.0.0.1"
DEFAULT_CDH_PORT = 8006
DEFAULT_OUT_DIR = "/tmp/kbs-key"
DEFAULT_TIMEOUT = 30


def fetch_resource(cdh_host: str, cdh_port: int, resource_path: str, timeout: int) -> bytes:
    url = f"http://{cdh_host}:{cdh_port}/cdh/resource/{resource_path}"
    response = requests.get(url, timeout=timeout)
    response.raise_for_status()
    return response.content


def parse_key_material(raw: bytes) -> tuple[str, str]:
    payload = json.loads(raw)
    key = payload["key"]
    nonce = payload["nonce"]
    # Fail fast on malformed base64 rather than writing bad files silently.
    base64.b64decode(key)
    base64.b64decode(nonce)
    return key, nonce


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resource-path", default=DEFAULT_RESOURCE_PATH)
    parser.add_argument("--cdh-host", default=DEFAULT_CDH_HOST)
    parser.add_argument("--cdh-port", type=int, default=DEFAULT_CDH_PORT)
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)

    print(f"Requesting KBS resource '{args.resource_path}' via CDH at "
          f"{args.cdh_host}:{args.cdh_port} (attestation-gated)...")

    try:
        raw = fetch_resource(args.cdh_host, args.cdh_port, args.resource_path, args.timeout)
        key, nonce = parse_key_material(raw)
    except Exception as exc:  # noqa: BLE001 - any failure here must abort, whatever the cause
        print("=" * 70, file=sys.stderr)
        print("KEY RELEASE FAILED - could not obtain the decryption key from KBS.", file=sys.stderr)
        print(f"Reason: {exc}", file=sys.stderr)
        print("This means either attestation failed, the resource policy denied", file=sys.stderr)
        print("release, or CDH/KBS is unreachable. Aborting BEFORE decryption.", file=sys.stderr)
        print("decrypt.py must not run.", file=sys.stderr)
        print("=" * 70, file=sys.stderr)
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "encryption.key").write_text(key)
    (out_dir / "encryption.nonce").write_text(nonce)

    print(f"Key material released and written to '{out_dir}'. Proceeding to decrypt.py.")


if __name__ == "__main__":
    main()
