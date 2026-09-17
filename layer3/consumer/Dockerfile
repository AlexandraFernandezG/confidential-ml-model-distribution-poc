# Builds on top of the already-built Layer 1 + Layer 2 consumer image -
# build consumer/Dockerfile as confidential-ml-consumer:latest, then
# layer2/consumer/Dockerfile on top (same tag), then this one (same tag
# again). See the top-level README for the full build sequence.
FROM confidential-ml-consumer:latest

WORKDIR /app

COPY requirements.txt ./layer3-requirements.txt
RUN pip install --no-cache-dir -r layer3-requirements.txt

COPY src/ ./layer3/src/

# This image must run under the kata-qemu-coco-dev RuntimeClass (see
# layer3/k8s/pod-consumer.yaml) - the Confidential Data Hub endpoint at
# 127.0.0.1:8006 used by fetch_key_kbs.py is only reachable from inside
# that confidential VM, not from a normal pod/runc container.
#
# Run all five steps in sequence, e.g.:
#   python src/fetch_artifact.py --repo-id <user>/<repo>
#   python layer2/src/verify_signature.py --repo-id <user>/<repo>
#   python layer3/src/fetch_key_kbs.py
#   python src/decrypt.py --key-path /tmp/kbs-key/encryption.key --nonce-path /tmp/kbs-key/encryption.nonce
#   python src/load_model.py
ENTRYPOINT ["python"]
CMD ["layer3/src/fetch_key_kbs.py", "--help"]
