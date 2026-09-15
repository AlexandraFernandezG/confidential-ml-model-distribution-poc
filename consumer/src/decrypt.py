"""
Layer 1 - Consumer step 2: decrypt the downloaded artifact with
AES-256-GCM, using the key and nonce mounted from the Kubernetes Secret.

Default key/nonce paths match the Secret volume mount configured in
k8s/pod-consumer.yaml (read-only, scoped to the consumer ServiceAccount).

NOTE: like the producer, this PoC buffers the whole artifact in memory to
decrypt it in a single AESGCM.decrypt() call. A production-scale model
would need chunked/streaming AEAD instead.
"""

import argparse
import base64
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

DEFAULT_ARTIFACT_PATH = "out/model.tar.enc"
DEFAULT_KEY_PATH = "/mnt/secrets/encryption.key"
DEFAULT_NONCE_PATH = "/mnt/secrets/encryption.nonce"
DEFAULT_OUT_PATH = "out/model.tar"


def load_key_material(key_path: Path, nonce_path: Path) -> tuple[bytes, bytes]:
    key = base64.b64decode(key_path.read_text().strip())
    nonce = base64.b64decode(nonce_path.read_text().strip())
    return key, nonce


def decrypt(ciphertext: bytes, key: bytes, nonce: bytes) -> bytes:
    return AESGCM(key).decrypt(nonce, ciphertext, associated_data=None)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-path", default=DEFAULT_ARTIFACT_PATH)
    parser.add_argument("--key-path", default=DEFAULT_KEY_PATH)
    parser.add_argument("--nonce-path", default=DEFAULT_NONCE_PATH)
    parser.add_argument("--out-path", default=DEFAULT_OUT_PATH)
    args = parser.parse_args()

    artifact_path = Path(args.artifact_path)
    key_path = Path(args.key_path)
    nonce_path = Path(args.nonce_path)
    out_path = Path(args.out_path)

    print(f"Loading key material from '{key_path}' / '{nonce_path}'...")
    key, nonce = load_key_material(key_path, nonce_path)

    print(f"Decrypting '{artifact_path}'...")
    ciphertext = artifact_path.read_bytes()
    plaintext = decrypt(ciphertext, key, nonce)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(plaintext)
    print(f"Decrypted artifact written to '{out_path}'.")


if __name__ == "__main__":
    main()
