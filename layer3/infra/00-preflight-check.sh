#!/usr/bin/env bash
# Layer 3 preflight: verify the target Linux host can actually run
# kata-qemu-coco-dev BEFORE any CoCo/KBS install is attempted.
#
# kata-qemu-coco-dev launches a real QEMU/KVM micro-VM per pod, so this
# will not work on typical managed Kubernetes, Docker Desktop's built-in
# cluster, or a host without nested virtualization. Run this on the node(s)
# that will actually run the consumer pod (or once per node in a
# multi-node cluster).
#
# Usage:
#   ./layer3/infra/00-preflight-check.sh
#
# Exits non-zero if any check fails. 01-install-coco-operator.sh assumes
# this has already passed.

set -uo pipefail

FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "      $2" >&2; FAIL=1; }

# 1. KVM device present and accessible (nested virt).
if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    pass "/dev/kvm present and accessible"
  else
    fail "/dev/kvm exists but isn't readable/writable by this user" \
         "add your user to the 'kvm' group (sudo usermod -aG kvm \$USER), then re-login"
  fi
else
  fail "/dev/kvm not found - nested virtualization is not enabled" \
       "Hyper-V host: run 'Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions \$true' from Windows (VM must be stopped), then restart the VM. VMware/VirtualBox: enable 'virtualize Intel VT-x/EPT' or 'nested VT-x/AMD-V' in the VM's CPU settings. Bare metal: enable VT-x/AMD-V and 'SVM/VMX nested' in BIOS."
fi

# 2. Ubuntu version >= 22.04.
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    MAJOR="${VERSION_ID%%.*}"
    if [[ "$MAJOR" =~ ^[0-9]+$ ]] && (( MAJOR >= 22 )); then
      pass "Ubuntu ${VERSION_ID} (>= 22.04)"
    else
      fail "Ubuntu ${VERSION_ID} is older than the required 22.04" \
           "upgrade to Ubuntu 22.04 or newer"
    fi
  else
    fail "distro is '${ID:-unknown}', not Ubuntu" \
         "this setup is only validated on Ubuntu 22.04+; other distros may work but aren't covered by these scripts"
  fi
else
  fail "/etc/os-release not found - cannot determine distro/version" \
       "confirm manually this is Ubuntu 22.04+"
fi

# 3. containerd is the active CRI (not CRI-O, not dockershim).
# crictl needs root to read containerd's socket by default, so use sudo
# when not already running as root.
if command -v crictl >/dev/null 2>&1; then
  CRICTL_CMD="crictl"
  if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    CRICTL_CMD="sudo crictl"
  fi
  RUNTIME_INFO="$(${CRICTL_CMD} info 2>/dev/null | grep -i '"runtimeName"' || true)"
  if echo "$RUNTIME_INFO" | grep -qi containerd; then
    pass "containerd is the active CRI"
  elif [[ -n "$RUNTIME_INFO" ]]; then
    fail "active CRI does not look like containerd: ${RUNTIME_INFO}" \
         "kata-qemu-coco-dev requires containerd, not CRI-O or dockershim"
  else
    fail "could not determine the active CRI via 'crictl info'" \
         "confirm manually that containerd is the configured CRI (check /etc/containerd/config.toml and kubelet --container-runtime-endpoint)"
  fi
elif systemctl is-active --quiet containerd 2>/dev/null; then
  pass "containerd service is active (crictl not available to confirm it's the configured CRI)"
else
  fail "neither 'crictl' nor an active 'containerd' service was found" \
       "install/start containerd and point the kubelet at it"
fi

# 4. No NoSchedule/NoExecute taints blocking pods on worker nodes.
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
  TAINTED="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .spec.taints[*]}{.effect}{","}{end}{"\n"}{end}' 2>/dev/null | grep -E '=.*(NoSchedule|NoExecute)' || true)"
  if [[ -z "$TAINTED" ]]; then
    pass "no NoSchedule/NoExecute taints found on cluster nodes"
  else
    fail "one or more nodes have NoSchedule/NoExecute taints: ${TAINTED}" \
         "remove the taint (kubectl taint nodes <node> <key>:<effect>-) or add a matching toleration to the consumer pod"
  fi
else
  fail "kubectl not available or cluster not reachable - cannot check node taints" \
       "run this after the cluster is up and KUBECONFIG is set, or check taints manually"
fi

# 5. SELinux not in Enforcing mode.
if command -v getenforce >/dev/null 2>&1; then
  SESTATUS="$(getenforce)"
  if [[ "$SESTATUS" == "Enforcing" ]]; then
    fail "SELinux is Enforcing" \
         "set to Permissive (sudo setenforce 0) or Disabled for this PoC - Kata's QEMU hypervisor process needs access patterns that a default Enforcing policy may block"
  else
    pass "SELinux is '${SESTATUS}' (not Enforcing)"
  fi
else
  pass "SELinux tooling not present (assumed not applicable, e.g. stock Ubuntu without SELinux)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "All preflight checks passed."
  exit 0
else
  echo "One or more preflight checks failed - fix these before running 01-install-coco-operator.sh." >&2
  exit 1
fi
