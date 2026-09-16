"""
Layer 1 - Consumer step 1: download the encrypted model artifact from
Hugging Face Hub.

This only fetches the ciphertext (model.tar.enc). The decryption key and
nonce come from the Kubernetes Secret mounted into this pod (see
decrypt.py), never from the Hub.
"""

import argparse
from pathlib import Path

from huggingface_hub import hf_hub_download

DEFAULT_FILENAME = "model.tar.enc"


def fetch_artifact(
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-id", required=True, help="e.g. your-username/bert-tiny-encrypted")
    parser.add_argument("--repo-type", default="model", choices=["model", "dataset"])
    parser.add_argument("--filename", default=DEFAULT_FILENAME)
    parser.add_argument("--out-dir", default="out")
    parser.add_argument("--token", default=None, help="defaults to HF_TOKEN env var / cached login")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Downloading '{args.filename}' from '{args.repo_id}' ({args.repo_type})...")
    artifact_path = fetch_artifact(args.repo_id, args.repo_type, args.filename, out_dir, args.token)
    print(f"Downloaded to '{artifact_path}'.")


if __name__ == "__main__":
    main()
