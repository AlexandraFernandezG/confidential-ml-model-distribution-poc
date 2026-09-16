# Builds on top of the already-built Layer 1 consumer image - build
# consumer/Dockerfile as confidential-ml-consumer:latest first (see
# top-level README), then build this one.
FROM confidential-ml-consumer:latest

WORKDIR /app

COPY requirements.txt ./layer2-requirements.txt
RUN pip install --no-cache-dir -r layer2-requirements.txt

COPY src/ ./layer2/src/

# Public key is expected to be mounted from a ConfigMap (not a Secret) at
# /mnt/publickey - see k8s/configmap-public-key.yaml and
# scripts/create-configmap.sh.
#
# Run all four steps in sequence, e.g.:
#   python src/fetch_artifact.py --repo-id <user>/<repo>
#   python layer2/src/verify_signature.py --repo-id <user>/<repo>
#   python src/decrypt.py
#   python src/load_model.py
ENTRYPOINT ["python"]
CMD ["layer2/src/verify_signature.py", "--help"]
