# Layer 2 (optional) - Model Signing & Verification

Extends [Layer 1](../README.md) with signing and verification: the
Producer signs the *encrypted* artifact with an Ed25519 private key, and
the Consumer verifies that signature **before decryption takes place**,
aborting immediately if it fails. This proves the artifact was produced by
the Producer's key and hasn't been tampered with or swapped in transit -
something AES-256-GCM alone doesn't guarantee, since GCM's auth tag only
proves the ciphertext wasn't altered *after* encryption by whoever holds
the symmetric key, not *who* produced it.

This is independent of [Layer 3](../layer3/README.md) and doesn't change
any Layer 1 file - it only inserts a verification step between
`fetch_artifact.py` and `decrypt.py` on the consumer side, and a signing
step after encryption on the producer side.

## Why Ed25519

Uses `cryptography.hazmat.primitives.asymmetric.ed25519` - the same
`cryptography` library Layer 1 already uses for AES-256-GCM, so no new
dependency is introduced. Ed25519 keys/signatures are small (32-byte
public key, 64-byte signature), signing is deterministic (no per-signature
randomness to get wrong, unlike RSA-PSS/ECDSA), and it's purpose-built for
signing rather than a repurposed general-purpose algorithm.

## Architecture

```
Producer                                   Hugging Face Hub          Consumer (pod)
--------                                   -----------------         ---------------
(Layer 1: select_and_encrypt.py,
 push_artifact.py - unchanged)                                       (Layer 1: fetch_artifact.py - unchanged)
        |                                                                    |
generate_keys.py                                                            fetch_artifact.py downloads
  Ed25519 keypair                                                            model.tar.enc
  writes: producer_ed25519.key (private,                                    |
          stays with Producer/Control Plane),                        verify_signature.py
          producer_ed25519.pub (public)                                downloads model.tar.enc.sig
        |                                                               verifies signature against
sign_artifact.py                                                        mounted public key
  signs model.tar.enc (ciphertext)          model.tar.enc                    |
  uploads model.tar.enc.sig  -------------> model.tar.enc.sig    FAIL -> abort, exit non-zero,
                                                                          decrypt.py never runs
Control Plane (scripts/create-configmap.sh)                              |
  reads producer_ed25519.pub                                       PASS -> proceed to
  kubectl create configmap                                          (Layer 1: decrypt.py,
  model-verification-key  ----------------------------------------->  load_model.py - unchanged)
    mounted read-only at /mnt/publickey in the pod
```

The public key is delivered via a **ConfigMap** created by the Control
Plane (same trust boundary that creates the decryption-key Secret in
Layer 1), **not** published to Hugging Face Hub alongside the artifact.
This matters: the artifact and its signature both travel over the Hub, so
if the verification key also came from the Hub, anyone able to write to
that repo could publish a tampered artifact, sign it with their own key,
and publish that key too - verification would "succeed" against a forged
trust root. Keeping the public key on an independent channel (the Control
Plane / cluster config, mirroring how the decryption key already reaches
the pod) is what makes the verification step meaningful. See
`k8s/configmap-public-key.yaml` for why this is a ConfigMap and not a
Secret - the public key isn't secret data, only the private key is.

## Running it

### 1. Producer: generate keys, sign, and publish

Run after the Layer 1 producer steps (`select_and_encrypt.py`,
`push_artifact.py`):

```bash
cd layer2/producer
pip install -r requirements.txt
python src/generate_keys.py --out-dir ../../out
python src/sign_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --out-dir ../../out
```

`../../out/producer_ed25519.key` stays local - do not commit or upload it.
`../../out/producer_ed25519.pub` is handed to the Control Plane next.

Or as a container, layered on top of the Layer 1 producer image:

```bash
docker build -t confidential-ml-producer-l2 layer2/producer/
docker run --rm -v "$PWD/out:/out" confidential-ml-producer-l2 src/generate_keys.py --out-dir /out
docker run --rm -v "$PWD/out:/out" -e HF_TOKEN confidential-ml-producer-l2 src/sign_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --out-dir /out
```

### 2. Control Plane/CI: publish the verification key to the cluster

```bash
./scripts/create-configmap.sh out confidential-ml-poc model-verification-key
```

### 3. Consumer: build and deploy

`k8s/pod-consumer.yaml` already includes the `verify_signature.py` step
and the `verification-key` ConfigMap mount (see top-level README for full
deploy instructions). Build the layered consumer image on top of the
already-built Layer 1 image:

```bash
docker build -t confidential-ml-consumer:latest consumer/       # Layer 1 image, if not already built
docker build -t confidential-ml-consumer:latest layer2/consumer/ # layers Layer 2 on top, same tag
kubectl apply -f k8s/configmap-public-key.yaml   # reference only - use create-configmap.sh instead
kubectl apply -f k8s/pod-consumer.yaml
kubectl logs -f consumer -n confidential-ml-poc
```

(The second `docker build` reuses the `confidential-ml-consumer:latest`
tag as its own `FROM`, so build it after the first and re-tag the result -
`docker build -t confidential-ml-consumer:latest layer2/consumer/`
overwrites the tag with the layered image, which is what
`k8s/pod-consumer.yaml` expects to pull.)

You can also run the consumer scripts locally against `out/` (as in
Layer 1) to sanity-check before containerizing:

```bash
cd layer2/consumer
pip install -r requirements.txt
python src/verify_signature.py --repo-id <your-hf-username>/bert-tiny-encrypted --artifact-path ../../out/model.tar.enc --public-key-path ../../out/producer_ed25519.pub --out-dir ../../out
```

## Demonstrating the abort-on-tampered-artifact case

After running the producer and consumer steps above at least once (so a
valid signed artifact exists on the Hub and `out/producer_ed25519.pub`
exists locally):

```bash
./layer2/scripts/demo-tamper.sh <your-hf-username>/bert-tiny-encrypted
```

This fetches the real artifact and verifies it (pass), flips one byte of
the local copy, and re-runs verification against the corrupted copy,
showing it exits non-zero with a `SIGNATURE VERIFICATION FAILED` message
instead of proceeding.

To reproduce it by hand instead:

```bash
python consumer/src/fetch_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --out-dir out
# corrupt out/model.tar.enc by any means (edit a byte, truncate it, etc.)
python layer2/consumer/src/verify_signature.py --repo-id <your-hf-username>/bert-tiny-encrypted --artifact-path out/model.tar.enc --public-key-path out/producer_ed25519.pub --out-dir out
# expect: non-zero exit, "SIGNATURE VERIFICATION FAILED", decrypt.py not run
```

The same happens if `model.tar.enc.sig` on the Hub is replaced with a
signature from a different key pair, or if a wrong/mismatched
`producer_ed25519.pub` is mounted at `/mnt/publickey`.
