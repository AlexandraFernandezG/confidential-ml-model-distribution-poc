"""
Layer 1 - Consumer step 3: extract the decrypted tar artifact, load the
model with transformers/PyTorch, and run a smoke-test inference to prove
the end-to-end pipeline (encrypt -> publish -> mount key -> fetch ->
decrypt -> load -> infer) worked.
"""

import argparse
import tarfile
from pathlib import Path

from transformers import BertModel, BertTokenizer

DEFAULT_TAR_PATH = "out/model.tar"
DEFAULT_EXTRACT_DIR = "out/model"
SMOKE_TEST_TEXT = "Confidential model distribution proof of concept."


def extract_tar(tar_path: Path, extract_dir: Path) -> Path:
    with tarfile.open(tar_path) as tar:
        tar.extractall(extract_dir, filter="data")
        top_level_dirs = {member.name.split("/")[0] for member in tar.getmembers()}

    if len(top_level_dirs) != 1:
        raise ValueError(f"Expected a single top-level dir in '{tar_path}', found {top_level_dirs}")

    return extract_dir / next(iter(top_level_dirs))


def run_smoke_test(model_dir: Path) -> None:
    # prajjwal1/bert-tiny's config.json predates the `model_type` field, so
    # AutoModel/AutoTokenizer can't infer the architecture from it. The
    # architecture is loaded explicitly since this PoC is built around this
    # one fixed model (see producer/src/select_and_encrypt.py).
    tokenizer = BertTokenizer.from_pretrained(model_dir)
    model = BertModel.from_pretrained(model_dir)
    model.eval()

    inputs = tokenizer(SMOKE_TEST_TEXT, return_tensors="pt")
    outputs = model(**inputs)

    print(f"Inference OK. last_hidden_state shape: {tuple(outputs.last_hidden_state.shape)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tar-path", default=DEFAULT_TAR_PATH)
    parser.add_argument("--extract-dir", default=DEFAULT_EXTRACT_DIR)
    args = parser.parse_args()

    tar_path = Path(args.tar_path)
    extract_dir = Path(args.extract_dir)

    print(f"Extracting '{tar_path}' to '{extract_dir}'...")
    model_dir = extract_tar(tar_path, extract_dir)

    print(f"Loading model from '{model_dir}' and running smoke-test inference...")
    run_smoke_test(model_dir)


if __name__ == "__main__":
    main()
