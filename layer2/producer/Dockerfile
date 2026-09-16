FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# Runs after the Layer 1 producer image (producer/Dockerfile) - expects
# out/model.tar.enc to already exist in the mounted --out-dir. No RBAC/
# cluster access is granted to this image, same as Layer 1's producer.
#
# Run one of:
#   python src/generate_keys.py --out-dir /out
#   python src/sign_artifact.py --repo-id <user>/<repo> --out-dir /out
ENTRYPOINT ["python"]
CMD ["src/generate_keys.py", "--help"]
