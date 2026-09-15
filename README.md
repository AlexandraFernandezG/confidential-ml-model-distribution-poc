# Confidential ML Model Distribution PoC

Proof-of-concept for a confidential LLM model delivery pipeline: a
**Producer** encrypts a model and publishes it to Hugging Face Hub, and a
**Consumer** running in Kubernetes downloads, decrypts, and loads it -
never letting the plaintext model or the decryption key leave a trusted
boundary unnecessarily.

The project has three progressive layers. Only **Layer 1** is implemented
here; Layers 2 and 3 are optional and independent of each other, and the
repo is structured so they can be added later without reworking Layer 1.

| Layer | Status | Adds |
|---|---|---|
| 1 - Encrypted distribution | **Implemented** | AES-256-GCM encryption, Hugging Face Hub as transport, key delivered via a Kubernetes Secret |
| 2 - Signing & verification | Not implemented ([layer2/](layer2/)) | Producer signs the encrypted artifact; Consumer verifies before decrypting |
| 3 - Attested key release | Not implemented ([layer3/](layer3/)) | Kata + CoCo, Trustee KBS, and Confidential Data Hub replace the Secret with attestation-gated key release |

## Architecture (Layer 1)

```
Producer                                Hugging Face Hub          Consumer (pod)
--------                                -----------------         ---------------
select_and_encrypt.py                                              (ServiceAccount: consumer-sa)
  download prajjwal1/bert-tiny
  tar -> AES-256-GCM encrypt
  writes: model.tar.enc,
          encryption.key, encryption.nonce
        |
push_artifact.py
  uploads model.tar.enc  ------------->  model.tar.enc
                                              |
                                              |  fetch_artifact.py
                                              v  downloads model.tar.enc
                                         (into consumer pod)

Control Plane / CI (scripts/create-secret.sh)
  reads encryption.key + encryption.nonce
  kubectl create secret model-decryption-key  ----->  mounted read-only at
                                                        /mnt/secrets in the pod
                                                              |
                                                              v
                                                        decrypt.py
                                                          AES-256-GCM decrypt
                                                          using mounted key/nonce
                                                              |
                                                              v
                                                        load_model.py
                                                          extract tar, load with
                                                          transformers, run smoke
                                                          test inference
```

See `docs/layer1-architecture.png` for a visual diagram.

Key points:

- The decryption **key and nonce never touch the Producer's cluster
  credentials** - Secret creation is a separate Control Plane/CI step
  (`scripts/create-secret.sh`), so the Producer image needs no RBAC
  permissions at all.
- The Consumer's Secret mount is read-only, scoped to a dedicated
  namespace (`confidential-ml-poc`) and ServiceAccount (`consumer-sa`),
  see `k8s/rbac-consumer.yaml`.
- AES-256-GCM is authenticated encryption: a corrupted or tampered
  ciphertext fails the GCM tag check in `decrypt.py` and aborts rather
  than silently returning garbage.

## Prerequisites

- Python 3.11+ (to run producer/consumer scripts locally, e.g. to test
  before containerizing)
- Docker, to build the producer and consumer images
- A container registry you can push to (e.g. Docker Hub, GHCR) and pull
  from inside your cluster
- `kubectl`, pointed at a running Kubernetes cluster (Docker Desktop's
  local cluster works fine for this PoC)
- A Hugging Face account with a write-enabled access token, either via
  `huggingface-cli login` or the `HF_TOKEN` environment variable

## Running it

### 1. Producer: encrypt and publish

Run locally (no cluster access needed - the producer never touches the
cluster):

```bash
cd producer
pip install -r requirements.txt
python src/select_and_encrypt.py --out-dir ../out
python src/push_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --artifact-path ../out/model.tar.enc
```

This downloads `prajjwal1/bert-tiny`, encrypts it, and uploads
`model.tar.enc` to your Hugging Face Hub repo. `../out/encryption.key` and
`../out/encryption.nonce` stay local - do not commit or upload them.

Alternatively, build and run the producer as a container:

```bash
docker build -t confidential-ml-producer producer/
docker run --rm -v "$PWD/out:/out" -e HF_TOKEN confidential-ml-producer src/select_and_encrypt.py --out-dir /out
docker run --rm -v "$PWD/out:/out" -e HF_TOKEN confidential-ml-producer src/push_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --artifact-path /out/model.tar.enc
```

### 2. Control Plane/CI: create cluster resources and the Secret

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/serviceaccount-consumer.yaml
kubectl apply -f k8s/rbac-consumer.yaml
./scripts/create-secret.sh out confidential-ml-poc model-decryption-key
```

### 3. Consumer: build, push, and deploy

```bash
docker build -t <your-registry>/confidential-ml-consumer:latest consumer/
docker push <your-registry>/confidential-ml-consumer:latest
```

Update `k8s/pod-consumer.yaml`'s `image` and `HF_REPO_ID` placeholders to
match, then:

```bash
kubectl apply -f k8s/pod-consumer.yaml
kubectl logs -f consumer -n confidential-ml-poc
```

You can also run the three consumer scripts locally (outside the cluster)
against the local `out/encryption.key` / `out/encryption.nonce` from step
1, to sanity-check the pipeline before containerizing/deploying:

```bash
cd consumer
pip install -r requirements.txt
python src/fetch_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --out-dir ../out
python src/decrypt.py --artifact-path ../out/model.tar.enc --key-path ../out/encryption.key --nonce-path ../out/encryption.nonce --out-path ../out/model.tar
python src/load_model.py --tar-path ../out/model.tar --extract-dir ../out/model
```

## Verifying each layer works

### Layer 1 (implemented)

- **Secret exists and is scoped correctly:**
  `kubectl get secret model-decryption-key -n confidential-ml-poc` should
  show `Data: encryption.key, encryption.nonce`; confirm only `consumer-sa`
  can read it via `kubectl auth can-i get secret/model-decryption-key --as=system:serviceaccount:confidential-ml-poc:consumer-sa -n confidential-ml-poc`
  (expect `yes`) versus the `default` ServiceAccount (expect `no`).
- **End-to-end pipeline succeeded:** `kubectl logs consumer -n confidential-ml-poc`
  ends with a line like `Inference OK. last_hidden_state shape: (1, N, 128)`
  - this only happens if the artifact was fetched, decrypted, extracted,
    and loaded successfully.
- **Authenticated encryption actually protects the artifact:** corrupt a
  byte of `out/model.tar.enc` or point `decrypt.py` at the wrong key and
  re-run it - it should raise `cryptography.exceptions.InvalidTag` and
  exit non-zero rather than producing corrupted model output.

### Layer 2 / Layer 3 (not implemented)

Not built in this repo - see [layer2/README.md](layer2/README.md) and
[layer3/README.md](layer3/README.md) for what verification would look
like once added (signature check before decrypting; attestation-gated key
release from the KBS instead of a mounted Secret).

## Scale note

This PoC buffers the entire model artifact in memory for a single
`encrypt()`/`decrypt()` call, which is fine at `bert-tiny` size. A
production-scale model would need **chunked/streaming AEAD** instead -
encrypting/decrypting fixed-size frames with per-frame nonces derived from
a base nonce, so the whole model never has to fit in memory at once.

## Repo structure

```
.
├── producer/    Layer 1: select model, encrypt, push to HF Hub
├── consumer/    Layer 1: fetch, decrypt, load + smoke-test inference
├── k8s/         Namespace, ServiceAccount, RBAC, Secret template, Pod spec
├── scripts/     Control Plane/CI step: create-secret.sh
├── docs/        Architecture diagram
├── layer2/      Placeholder: signing & verification (optional, not implemented)
└── layer3/      Placeholder: attested key release via CoCo (optional, not implemented)
```
