"""
Layer 2 - Consumer step (runs BEFORE decrypt.py): download the artifact's
signature from Hugging Face Hub and verify it against the Producer's
Ed25519 public key.

This must run before decrypt.py. If verification fails, the process exits
non-zero and decrypt.py must never run - an unverified artifact must never
be decrypted. In the k8s pod command chain (see k8s/pod-consumer.yaml) this
is enforced by shell `&&`: a non-zero exit here short-circuits the rest of
the chain.

The public key is expected to be mounted from a ConfigMap (not a Secret -
it isn't secret data) at /mnt/publickey, delivered by the Control Plane via
scripts/create-configmap.sh. It is deliberately NOT fetched from Hugging
Face Hub: the artifact and signature both travel over the Hub, so the
verification key must come from an independent channel, or a compromised
Hub repo could ship a tampered artifact, a matching forged signature, and
a matching forged public key together.
"""

import argparse
import sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from huggingface_hub import hf_hub_download

DEFAULT_SIGNATURE_FILENAME = "model.tar.enc.sig"
DEFAULT_ARTIFACT_PATH = "out/model.tar.enc"
DEFAULT_PUBLIC_KEY_PATH = "/mnt/publickey/producer_ed25519.pub"
DEFAULT_OUT_DIR = "out"


def fetch_signature(
    repo_id: str,
    repo_type: str,
    filename: str,
    out_dir: Path,
    token: str | None,
) -> Path:
    downloaded_path = hf_hub_download(
        repo_id=repo_id,
        repo_type=repo_type,
        filename=filename,
        local_dir=str(out_dir),
        token=token,
    )
    return Path(downloaded_path)


def load_public_key(public_key_path: Path) -> Ed25519PublicKey:
    return serialization.load_pem_public_key(public_key_path.read_bytes())


def verify(ciphertext: bytes, signature: bytes, public_key: Ed25519PublicKey) -> bool:
    try:
        public_key.verify(signature, ciphertext)
        return True
    except InvalidSignature:
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-id", required=True, help="e.g. your-username/bert-tiny-encrypted")
    parser.add_argument("--repo-type", default="model", choices=["model", "dataset"])
    parser.add_argument("--signature-filename", default=DEFAULT_SIGNATURE_FILENAME)
    parser.add_argument("--artifact-path", default=DEFAULT_ARTIFACT_PATH)
    parser.add_argument("--public-key-path", default=DEFAULT_PUBLIC_KEY_PATH)
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--token", default=None, help="defaults to HF_TOKEN env var / cached login")
    args = parser.parse_args()

    artifact_path = Path(args.artifact_path)
    public_key_path = Path(args.public_key_path)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not artifact_path.exists():
        print(f"error: '{artifact_path}' not found - run fetch_artifact.py first.", file=sys.stderr)
        sys.exit(1)
    if not public_key_path.exists():
        print(f"error: '{public_key_path}' not found - is the public-key ConfigMap mounted?", file=sys.stderr)
        sys.exit(1)

    print(f"Downloading '{args.signature_filename}' from '{args.repo_id}' ({args.repo_type})...")
    signature_path = fetch_signature(args.repo_id, args.repo_type, args.signature_filename, out_dir, args.token)

    print(f"Verifying '{artifact_path}' against '{signature_path}' using '{public_key_path}'...")
    public_key = load_public_key(public_key_path)
    ok = verify(artifact_path.read_bytes(), signature_path.read_bytes(), public_key)

    if not ok:
        print("=" * 70, file=sys.stderr)
        print("SIGNATURE VERIFICATION FAILED - artifact may be tampered or forged.", file=sys.stderr)
        print("Aborting BEFORE decryption. decrypt.py must not run.", file=sys.stderr)
        print("=" * 70, file=sys.stderr)
        sys.exit(1)

    print("Signature verification OK. Proceeding to decrypt.py.")


if __name__ == "__main__":
    main()
