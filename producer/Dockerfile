FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# No RBAC/cluster access is granted to this image - Secret creation is a
# separate Control Plane/CI step (see scripts/create-secret.sh).
#
# Run one of:
#   python src/select_and_encrypt.py --out-dir /out
#   python src/push_artifact.py --repo-id <user>/<repo> --artifact-path /out/model.tar.enc
ENTRYPOINT ["python"]
CMD ["src/select_and_encrypt.py", "--help"]
