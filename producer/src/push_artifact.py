"""
Layer 1 - Producer step 3: push the encrypted model artifact to Hugging
Face Hub.

Only the ciphertext (model.tar.enc) is uploaded here. The decryption key
and nonce produced by select_and_encrypt.py must never be pushed to the
Hub - they are handed off separately to scripts/create-secret.sh to become
a Kubernetes Secret.

Requires Hub write credentials, e.g. via `huggingface-cli login` or the
HF_TOKEN environment variable (picked up automatically by huggingface_hub
if --token is not passed).
"""

import argparse
from pathlib import Path

from huggingface_hub import HfApi

DEFAULT_ARTIFACT_PATH = "out/model.tar.enc"
ARTIFACT_PATH_IN_REPO = "model.tar.enc"


def push_artifact(
    artifact_path: Path,
    repo_id: str,
    repo_type: str,
    private: bool,
    token: str | None,
) -> str:
    api = HfApi(token=token)
    api.create_repo(repo_id=repo_id, repo_type=repo_type, private=private, exist_ok=True)
    return api.upload_file(
        path_or_fileobj=str(artifact_path),
        path_in_repo=ARTIFACT_PATH_IN_REPO,
        repo_id=repo_id,
        repo_type=repo_type,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-id", required=True, help="e.g. your-username/bert-tiny-encrypted")
    parser.add_argument("--artifact-path", default=DEFAULT_ARTIFACT_PATH)
    parser.add_argument("--repo-type", default="model", choices=["model", "dataset"])
    parser.add_argument("--private", action="store_true")
    parser.add_argument("--token", default=None, help="defaults to HF_TOKEN env var / cached login")
    args = parser.parse_args()

    artifact_path = Path(args.artifact_path)
    if not artifact_path.exists():
        raise FileNotFoundError(
            f"'{artifact_path}' not found - run select_and_encrypt.py first."
        )

    print(f"Uploading '{artifact_path}' to '{args.repo_id}' ({args.repo_type})...")
    url = push_artifact(artifact_path, args.repo_id, args.repo_type, args.private, args.token)
    print(f"Uploaded. Commit URL: {url}")


if __name__ == "__main__":
    main()
