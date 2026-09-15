# Layer 3 (optional) - Attested Key Release via Confidential Containers

Not implemented yet.

Replaces the Kubernetes Secret from Layer 1 with attested key release:

- Cluster runs Confidential Containers (Kata + CoCo) with the
  `kata-qemu-coco-dev` runtime class, so the consumer pod executes inside a
  hardware-attested confidential VM.
- A Trustee Key Broker Service (KBS) holds the decryption key instead of a
  Kubernetes Secret, and only releases it after the pod's runtime
  environment passes remote attestation.
- The consumer retrieves the key at runtime through the Confidential Data
  Hub (CDH) endpoint rather than reading it from a mounted Secret volume.

Layer 3 can sit on top of Layer 1 alone, or on top of Layer 1 + Layer 2 for
the full stack. It only changes how the consumer *obtains* the key
(`decrypt.py`'s key-loading step); the AES-256-GCM decryption logic itself
is unchanged, and it replaces `k8s/secret-decryption-key.yaml` /
`scripts/create-secret.sh` with KBS-side key provisioning instead of a
cluster Secret.
