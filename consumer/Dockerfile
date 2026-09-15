FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# Decryption key/nonce are expected to be mounted read-only from a
# Kubernetes Secret at /mnt/secrets (see k8s/pod-consumer.yaml), not baked
# into this image.
#
# Run all three steps in sequence, e.g.:
#   python src/fetch_artifact.py --repo-id <user>/<repo>
#   python src/decrypt.py
#   python src/load_model.py
ENTRYPOINT ["python"]
CMD ["src/fetch_artifact.py", "--help"]
