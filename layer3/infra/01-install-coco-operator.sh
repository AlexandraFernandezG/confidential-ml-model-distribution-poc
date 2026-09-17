#!/usr/bin/env bash
# Layer 3: install the Confidential Containers (CoCo) operator and deploy
# the ccruntime sample that provides the kata-qemu-coco-dev runtime class
# (per https://confidentialcontainers.org/blog/2024/12/03/confidential-containers-without-confidential-hardware/).
#
# Version pin: operator v0.10.0. Note the assignment spec asked for
# "v0.10.1" for reproducibility, but as of writing that tag does not exist
# on the confidential-containers/operator repo (it jumps from v0.10.0 to
# v0.11.0) - v0.10.0 is what the referenced tutorial itself uses, and is
# the closest reproducible match. Trustee (KBS), deployed separately by
# 02-deploy-kbs.sh, does have a real v0.10.1 tag and is pinned to that.
# A newer operator/Trustee version could be substituted later by changing
# OPERATOR_VERSION below.
#
# Usage:
#   ./layer3/infra/01-install-coco-operator.sh [worker-node-name ...]
# With no node names given, labels every node that is NOT tainted with
# node-role.kubernetes.io/control-plane.
#
# Prerequisite: 00-preflight-check.sh has passed. Set SKIP_PREFLIGHT=1 to
# skip re-running it (e.g. on a repeat invocation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_VERSION="v0.10.0"

if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
  echo "Running preflight checks (set SKIP_PREFLIGHT=1 to skip)..."
  "${SCRIPT_DIR}/00-preflight-check.sh"
fi

if [[ "$#" -gt 0 ]]; then
  WORKER_NODES=("$@")
else
  mapfile -t WORKER_NODES < <(
    kubectl get nodes -o json | \
    python3 -c '
import json, sys
nodes = json.load(sys.stdin)["items"]
for n in nodes:
    labels = n["metadata"].get("labels", {})
    if "node-role.kubernetes.io/control-plane" not in labels:
        print(n["metadata"]["name"])
'
  )
fi

if [[ "${#WORKER_NODES[@]}" -eq 0 ]]; then
  echo "error: no worker nodes found/given to label. Pass node name(s) explicitly:" >&2
  echo "  ./layer3/infra/01-install-coco-operator.sh <node-name> [<node-name> ...]" >&2
  exit 1
fi

echo "Labeling worker node(s) for the CoCo operator: ${WORKER_NODES[*]}"
for node in "${WORKER_NODES[@]}"; do
  kubectl label node "$node" "node.kubernetes.io/worker=" --overwrite
done

echo "Installing CoCo operator (${OPERATOR_VERSION})..."
kubectl apply -k "github.com/confidential-containers/operator/config/release?ref=${OPERATOR_VERSION}"

echo "Waiting for the operator deployment to become ready..."
kubectl rollout status deployment/cc-operator-controller-manager \
  -n confidential-containers-system --timeout=300s

echo "Deploying the ccruntime sample (provides kata-qemu-coco-dev)..."
kubectl apply -k "github.com/confidential-containers/operator/config/samples/ccruntime/default?ref=${OPERATOR_VERSION}"

echo "Waiting for the kata-qemu-coco-dev RuntimeClass to appear..."
for i in $(seq 1 60); do
  if kubectl get runtimeclass kata-qemu-coco-dev >/dev/null 2>&1; then
    echo "kata-qemu-coco-dev RuntimeClass is present."
    exit 0
  fi
  sleep 5
done

echo "error: kata-qemu-coco-dev RuntimeClass did not appear after 5 minutes." >&2
echo "Check the operator/daemonset pods: kubectl get pods -n confidential-containers-system" >&2
exit 1
