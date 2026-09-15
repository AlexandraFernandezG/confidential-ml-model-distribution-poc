"""
Layer 1 - Producer step 1-2: pull the model from Hugging Face Hub and
encrypt it with AES-256-GCM.

Outputs (written to --out-dir):
    model.tar.enc     ciphertext (GCM tag included) of the tarred model dir
    encryption.key    base64-encoded 32-byte AES-256 key
    encryption.nonce  base64-encoded 12-byte GCM nonce

The key/nonce files are consumed by scripts/create-secret.sh (a Control
Plane/CI step) to populate the Kubernetes Secret that the consumer mounts.
This script never touches the cluster itself.

NOTE: this PoC buffers the whole model artifact in memory for encryption,
which is fine at bert-tiny scale. A production-scale model would need
chunked/streaming AEAD (e.g. encrypt-and-upload in fixed-size frames with
a per-frame nonce) instead of a single encrypt() call over the full blob.
"""

import argparse
import base64
import io
import os
import tarfile
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from huggingface_hub import snapshot_download

DEFAULT_MODEL_ID = "prajjwal1/bert-tiny"
AES_KEY_SIZE_BYTES = 32  # AES-256
GCM_NONCE_SIZE_BYTES = 12  # 96-bit nonce, standard for GCM


def download_model(model_id: str, download_dir: Path) -> Path:
    return Path(snapshot_download(repo_id=model_id, local_dir=str(download_dir)))


def tar_directory(directory: Path) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        tar.add(directory, arcname=directory.name)
    return buffer.getvalue()


def encrypt(plaintext: bytes) -> tuple[bytes, bytes, bytes]:
    """Returns (ciphertext, key, nonce). Generates a fresh key and nonce
    every run so a nonce is never reused with a given key."""
    key = AESGCM.generate_key(bit_length=AES_KEY_SIZE_BYTES * 8)
    nonce = os.urandom(GCM_NONCE_SIZE_BYTES)
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, associated_data=None)
    return ciphertext, key, nonce


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--out-dir", default="out")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    download_dir = out_dir / "model_download"

    print(f"Downloading '{args.model_id}' from Hugging Face Hub...")
    model_dir = download_model(args.model_id, download_dir)

    print(f"Packaging '{model_dir}' into a tar artifact...")
    plaintext = tar_directory(model_dir)

    print("Encrypting artifact with AES-256-GCM...")
    ciphertext, key, nonce = encrypt(plaintext)

    (out_dir / "model.tar.enc").write_bytes(ciphertext)
    (out_dir / "encryption.key").write_text(base64.b64encode(key).decode("ascii"))
    (out_dir / "encryption.nonce").write_text(base64.b64encode(nonce).decode("ascii"))

    print(f"Wrote encrypted artifact and key material to '{out_dir}'.")


if __name__ == "__main__":
    main()
