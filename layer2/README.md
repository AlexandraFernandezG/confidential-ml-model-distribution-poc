# Layer 2 (optional) - Model Signing & Verification

Not implemented yet.

Adds signing/verification on top of Layer 1:

- Producer signs the encrypted artifact (`model.tar.enc`) with a private
  key after encryption, and publishes the signature alongside it on
  Hugging Face Hub.
- Consumer fetches the signature along with the artifact and verifies it
  with the corresponding public key **before** calling `decrypt.py`.
  Verification failure aborts the pipeline - the artifact is never
  decrypted.

This is independent of Layer 3 and can be added without changing Layer 1's
encryption/decryption logic; it only inserts a verification step between
`fetch_artifact.py` and `decrypt.py` on the consumer side, and a signing
step after encryption on the producer side.
