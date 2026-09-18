"""
Layer 2 - Producer step 1: generate an Ed25519 key pair used to sign the
encrypted model artifact.

Outputs (written to --out-dir):
    producer_ed25519.key   PEM-encoded Ed25519 private key (PKCS8, unencrypted)
    producer_ed25519.pub   PEM-encoded Ed25519 public key (SubjectPublicKeyInfo)

The private key must never leave the Producer / Control Plane boundary - it
is not uploaded to Hugging Face Hub and must not be committed to git (it is
written under the already-gitignored --out-dir, same as Layer 1's
encryption.key/encryption.nonce).

The public key is not secret. It is handed to the Control Plane separately
(see layer2/README.md and scripts/create-configmap.sh) so it can be
delivered to the Consumer pod via a ConfigMap - a channel independent of
Hugging Face Hub, since the artifact and its signature both travel over
the Hub and must not also be the source of the key used to verify them.

NOTE: PoC scope - this is a single long-lived key pair generated once and
reused for every signing run. A production setup would rotate keys and
track which public key verifies which signed artifact (e.g. a key id).
"""

import argparse
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

DEFAULT_PRIVATE_KEY_FILENAME = "producer_ed25519.key"
DEFAULT_PUBLIC_KEY_FILENAME = "producer_ed25519.pub"


def generate_keypair() -> tuple[bytes, bytes]:
    """Returns (private_key_pem, public_key_pem)."""
    private_key = Ed25519PrivateKey.generate()
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return private_pem, public_pem


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default="out")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print("Generating Ed25519 key pair...")
    private_pem, public_pem = generate_keypair()

    (out_dir / DEFAULT_PRIVATE_KEY_FILENAME).write_bytes(private_pem)
    (out_dir / DEFAULT_PUBLIC_KEY_FILENAME).write_bytes(public_pem)

    print(f"Wrote private key to '{out_dir / DEFAULT_PRIVATE_KEY_FILENAME}' - keep this on the Producer/Control Plane side only.")
    print(f"Wrote public key to '{out_dir / DEFAULT_PUBLIC_KEY_FILENAME}' - distribute this to the Consumer via a ConfigMap.")


if __name__ == "__main__":
    main()
