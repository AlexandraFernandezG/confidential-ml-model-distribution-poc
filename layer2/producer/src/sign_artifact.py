"""
Layer 2 - Producer step 2-3: sign the encrypted model artifact
(model.tar.enc, i.e. the ciphertext - not the plaintext model) with the
Ed25519 private key, and publish the resulting signature to Hugging Face
Hub alongside the artifact.

Signing the ciphertext (rather than the plaintext model) means the
Consumer can verify authenticity before ever decrypting - the whole point
of running verification ahead of decrypt.py in the pipeline.

Ed25519 signing is a single deterministic operation (no nonce/hash
pre-processing to get wrong, unlike RSA-PSS/ECDSA) over the raw artifact
bytes.

Requires Hub write credentials, same as producer/src/push_artifact.py.
"""

import argparse
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from huggingface_hub import HfApi

DEFAULT_ARTIFACT_PATH = "out/model.tar.enc"
DEFAULT_PRIVATE_KEY_PATH = "out/producer_ed25519.key"
DEFAULT_SIGNATURE_FILENAME = "model.tar.enc.sig"
SIGNATURE_PATH_IN_REPO = "model.tar.enc.sig"


def load_private_key(private_key_path: Path) -> Ed25519PrivateKey:
    return serialization.load_pem_private_key(private_key_path.read_bytes(), password=None)


def sign(ciphertext: bytes, private_key: Ed25519PrivateKey) -> bytes:
    return private_key.sign(ciphertext)


def push_signature(
    signature_path: Path,
    repo_id: str,
    repo_type: str,
    private: bool,
    token: str | None,
) -> str:
    api = HfApi(token=token)
    api.create_repo(repo_id=repo_id, repo_type=repo_type, private=private, exist_ok=True)
    return api.upload_file(
        path_or_fileobj=str(signature_path),
        path_in_repo=SIGNATURE_PATH_IN_REPO,
        repo_id=repo_id,
        repo_type=repo_type,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-path", default=DEFAULT_ARTIFACT_PATH)
    parser.add_argument("--private-key-path", default=DEFAULT_PRIVATE_KEY_PATH)
    parser.add_argument("--out-dir", default="out")
    parser.add_argument("--repo-id", required=True, help="e.g. your-username/bert-tiny-encrypted (same repo as the artifact)")
    parser.add_argument("--repo-type", default="model", choices=["model", "dataset"])
    parser.add_argument("--private", action="store_true")
    parser.add_argument("--token", default=None, help="defaults to HF_TOKEN env var / cached login")
    parser.add_argument("--skip-push", action="store_true", help="sign locally only, don't upload to the Hub")
    args = parser.parse_args()

    artifact_path = Path(args.artifact_path)
    private_key_path = Path(args.private_key_path)
    if not artifact_path.exists():
        raise FileNotFoundError(f"'{artifact_path}' not found - run select_and_encrypt.py first.")
    if not private_key_path.exists():
        raise FileNotFoundError(f"'{private_key_path}' not found - run generate_keys.py first.")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Signing '{artifact_path}' with '{private_key_path}'...")
    private_key = load_private_key(private_key_path)
    signature = sign(artifact_path.read_bytes(), private_key)

    signature_path = out_dir / DEFAULT_SIGNATURE_FILENAME
    signature_path.write_bytes(signature)
    print(f"Wrote signature to '{signature_path}'.")

    if args.skip_push:
        print("--skip-push set, not uploading to Hugging Face Hub.")
        return

    print(f"Uploading '{signature_path}' to '{args.repo_id}' ({args.repo_type})...")
    url = push_signature(signature_path, args.repo_id, args.repo_type, args.private, args.token)
    print(f"Uploaded. Commit URL: {url}")


if __name__ == "__main__":
    main()
