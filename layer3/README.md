# Layer 3 (optional) - Attested Key Release via Kata + CoCo

Extends [Layer 1](../README.md) (and combines with [Layer 2](../layer2/README.md)
for the full stack) by replacing the Kubernetes Secret from Layer 1 with
**attested key release**: the consumer no longer trusts the host/cluster
operator to hand it the decryption key directly. Instead, the key is held
in a Trustee Key Broker Service (KBS) and released only after the
consumer pod's runtime environment passes remote attestation, using
[Confidential Containers (CoCo)](https://confidentialcontainers.org/) and
Kata's `kata-qemu-coco-dev` runtime class.

This follows the CoCo project's own
["Confidential Containers without confidential hardware"](https://confidentialcontainers.org/blog/2024/12/03/confidential-containers-without-confidential-hardware/)
tutorial: `kata-qemu-coco-dev` launches a real QEMU/KVM micro-VM per pod
and goes through the full attestation protocol, but accepts a placeholder
`"sample"` TEE evidence type instead of requiring real confidential
hardware (SEV-SNP/TDX/etc.) - useful for demonstrating the mechanism
without needing that hardware, but **not a security boundary** (see
[Security disclaimers](#security-disclaimers)).

Layer 3 only changes *how the consumer obtains the decryption key*. It
does not change:
- the Producer (Layer 1 encrypt + Layer 2 sign, unchanged)
- the artifact/signature transport (Hugging Face Hub, unchanged)
- Layer 2's signature verification, which still runs before decryption,
  using the same ConfigMap-delivered Ed25519 public key
- `consumer/src/decrypt.py`'s AES-256-GCM logic itself (only where it
  gets its key/nonce *from* changes)

## Environment prerequisites

`kata-qemu-coco-dev` launches a real QEMU/KVM micro-VM per pod. This does
**not** work on typical managed Kubernetes or Docker Desktop's built-in
cluster. You need:

- A real Linux host - bare-metal, or a VM with **nested virtualization
  enabled** (so `/dev/kvm` exists inside it)
- Ubuntu 22.04 or newer
- Kubernetes 1.30+
- **containerd** as the container runtime (not CRI-O, not dockershim)
- No `NoSchedule`/`NoExecute` taints blocking pods on the node(s) that
  will run CoCo/the consumer pod
- SELinux not in `Enforcing` mode (Kata's QEMU hypervisor process needs
  access patterns a default Enforcing policy may block)

Run [`layer3/infra/00-preflight-check.sh`](infra/00-preflight-check.sh)
on the target host first - it checks all of the above mechanically and
exits non-zero with a specific remediation hint for whatever fails.

If your target is a **local VM on a Windows/Mac host** (VirtualBox,
VMware, Hyper-V), nested virtualization must be turned on in the
*hypervisor*, not just inside the guest:
- **Hyper-V**: from the Windows host (VM stopped): `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true` (requires Windows Pro/Enterprise/Education - not available on Windows Home)
- **VMware Workstation/Fusion**: enable "Virtualize Intel VT-x/EPT or AMD-V/RVI" in the VM's CPU settings
- **VirtualBox**: enable "Enable Nested VT-x/AMD-V" in the VM's System > Processor settings

If your target is an **AWS EC2 Ubuntu Server instance**, nested
virtualization is an instance CPU option, not a VM setting - AWS added
support for it on regular (non-bare-metal) instances in Feb 2026. Launch
a supported x86_64 instance type (`M7i`/`M7i-flex`/`M8i`/`C7i`/`C7i-flex`/`C8i`/
`R7i`/`R8i`/etc. - Graviton is not supported) with nested virtualization
enabled:

```bash
aws ec2 run-instances \
    --image-id <ubuntu-22.04-ami-id> \
    --instance-type m7i.2xlarge \
    --cpu-options "NestedVirtualization=enabled" \
    --key-name <your-key-pair>
```

Or via the console: Launch Instance wizard -> Advanced details -> Nested
virtualization -> Enable. Alternatively, any `.metal` bare-metal instance
type (e.g. `m5.metal`) exposes `/dev/kvm` with no special CPU option at
all, since there's no hypervisor layer above it - simpler but pricier.
Either way, verify with `kvm-ok` after boot (`sudo apt install cpu-checker`)
before running `00-preflight-check.sh`. See the
[AWS nested virtualization docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html)
for the full instance-type list and region availability. You'll also need
an inbound Security Group rule for the KBS NodePort (typically in the
`30000-32767` range) once you reach `02-deploy-kbs.sh`.

## Version pins

| Component | Version | Note |
|---|---|---|
| CoCo operator | **v0.10.0** | The assignment/tutorial reference version is "v0.10.1", but that tag does not exist on the [operator repo](https://github.com/confidential-containers/operator) (it jumps from v0.10.0 straight to v0.11.0). v0.10.0 is what the tutorial itself actually pins to, and is used here for reproducibility. |
| Trustee (KBS) | **v0.10.1** | This tag does genuinely exist (a small patch release on top of v0.10.0). |
| `oras` CLI | v1.3.4 | Only used to fetch the `kbs-client` binary; not a CoCo/Trustee component. |

A newer operator/Trustee version could be substituted later by changing
the version variables at the top of the `layer3/infra/*.sh` scripts.

## KBS deployment mode

KBS is deployed in **dev/test mode** on the same cluster as CoCo, via
Trustee's own `kbs/config/kubernetes/deploy-kbs.sh`, exposed via
NodePort. This is **not a production deployment**: no TLS, a locally
auto-generated (not HSM-backed) Ed25519 admin key pair, and a single
non-HA instance. See [Security disclaimers](#security-disclaimers).

## Resource path and policy

- The decryption key (+ nonce) is stored at KBS resource path
  `default/key/my-model`, as one JSON blob
  (`{"key": "<b64>", "nonce": "<b64>"}`) - KBS resources are single blobs
  at one path, but `decrypt.py` needs both values, so both are packed
  into that one resource. See
  [`layer3/infra/04-set-resource.sh`](infra/04-set-resource.sh).
- The resource policy
  ([`layer3/infra/resource-policy.rego`](infra/resource-policy.rego))
  allows release **only** when the attester reports TEE type `"sample"` -
  the only "attestation" possible without real confidential hardware.
  **This policy is insecure and for PoC/demo purposes only - never use it
  in production.** A real deployment would gate release on actual TEE
  evidence (SEV-SNP/TDX measurements, etc.).

## Architecture

```
Producer                    Hugging Face Hub         KBS (Trustee, dev/test)      Consumer (pod, kata-qemu-coco-dev)
--------                    -----------------         ----------------------      -----------------------------------
(Layer 1 + Layer 2:                                                               (Layer 1: fetch_artifact.py - unchanged)
 select_and_encrypt.py,                                                                  |
 push_artifact.py,                                                                (Layer 2: verify_signature.py - unchanged,
 generate_keys.py,                                                                 mounted public key from ConfigMap)
 sign_artifact.py -           model.tar.enc                                              |
 all unchanged)     -------> model.tar.enc.sig                                    FAIL -> abort, decrypt.py never runs
        |                                                                                |
        |                                                                          PASS -> fetch_key_kbs.py:
Control Plane/infra                                  default/key/my-model                GET http://127.0.0.1:8006/cdh/resource/default/key/my-model
  01-install-coco-operator.sh                          {"key": "...", "nonce": "..."}            |
  02-deploy-kbs.sh                                            ^                          (only reachable from INSIDE the
  03-fetch-kbs-client.sh                                      |                           confidential VM - proxied in by
  04-set-resource.sh    ---------------------------------------                           kata-agent/CDH after attestation)
  05-set-resource-policy.sh                                                                      |
    (resource-policy.rego:                          <--- remote attestation --->          FAIL (policy denies / attestation
     allow when tee == "sample")                     (kata-agent <-> KBS,                  fails) -> abort, decrypt.py
                                                       agent.aa_kbc_params annotation)       never runs
                                                                                                   |
                                                                                            PASS -> key/nonce written to
                                                                                             /tmp/kbs-key/, decrypt.py,
                                                                                             load_model.py (unchanged)
```

## Running it

All commands assume the repo root as the working directory, on the
target Linux host (see [Environment prerequisites](#environment-prerequisites)).

### 1. Cluster/infra setup (once per cluster)

```bash
./layer3/infra/00-preflight-check.sh
./layer3/infra/01-install-coco-operator.sh
./layer3/infra/02-deploy-kbs.sh
./layer3/infra/03-fetch-kbs-client.sh
```

`02-deploy-kbs.sh` writes `out/kbs-endpoint.env` with `KBS_HOST`/`KBS_PORT` -
subsequent steps and `layer3/k8s/pod-consumer.yaml` need those values.

### 2. Producer: encrypt, sign, and publish (Layer 1 + Layer 2, unchanged)

```bash
cd producer
python src/select_and_encrypt.py --out-dir ../out
python src/push_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --artifact-path ../out/model.tar.enc
cd ../layer2/producer
python src/generate_keys.py --out-dir ../../out
python src/sign_artifact.py --repo-id <your-hf-username>/bert-tiny-encrypted --artifact-path ../../out/model.tar.enc --private-key-path ../../out/producer_ed25519.key --out-dir ../../out
cd ../..
```

### 3. Control Plane: load the key + policy into KBS, publish the verification key

```bash
./layer3/infra/04-set-resource.sh
./layer3/infra/05-set-resource-policy.sh
./scripts/create-configmap.sh out confidential-ml-poc model-verification-key
```

(`create-configmap.sh` is unchanged from Layer 2 - it delivers the
Ed25519 public key, independent of the KBS flow.)

### 4. Consumer: build and deploy

```bash
docker build -t confidential-ml-consumer:latest consumer/        # Layer 1 image
docker build -t confidential-ml-consumer:latest layer2/consumer/ # + Layer 2, same tag
docker build -t confidential-ml-consumer:latest layer3/consumer/ # + Layer 3, same tag
```

Edit `layer3/k8s/pod-consumer.yaml`: set `<your-registry>`, `HF_REPO_ID`,
and `<KBS_HOST>`/`<KBS_PORT>` (from `out/kbs-endpoint.env`). Then:

```bash
kubectl apply -f k8s/configmap-public-key.yaml   # reference only - use create-configmap.sh instead
kubectl apply -f layer3/k8s/pod-consumer.yaml
kubectl logs -f consumer -n confidential-ml-poc
```

### 5. Verify the full attested flow

Expected log sequence: `fetch_artifact.py` downloads the artifact,
`verify_signature.py` prints "Signature verification OK", `fetch_key_kbs.py`
prints "Key material released and written to '/tmp/kbs-key'", `decrypt.py`
decrypts, and `load_model.py` loads the model successfully. If any step
before decryption fails, later steps never run (enforced by `&&` in the
pod command).

## Demonstrating the failure case

```bash
./layer3/scripts/demo-policy-deny.sh
```

Requires the normal flow above already working end-to-end. This script
temporarily pushes a deny-all resource policy
([`layer3/infra/deny-all-policy.rego`](infra/deny-all-policy.rego)) to
KBS, redeploys the consumer pod, and confirms via `kubectl logs`/exit code
that `fetch_key_kbs.py` printed `KEY RELEASE FAILED` and the container
exited non-zero - `decrypt.py` never ran. It restores the real permissive
policy afterward regardless of outcome.

## Security disclaimers

- **The dev/test KBS deployment is not production-grade**: no TLS between
  consumer and KBS, a locally auto-generated admin key pair, single
  instance, no HA/backup.
- **The `"sample"`-TEE resource policy is insecure by design**: without
  real confidential hardware, there is no actual hardware root of trust
  behind the attestation - any pod that can reach KBS through the
  `kata-qemu-coco-dev` guest agent and present `sample` evidence gets the
  key. This demonstrates the *mechanism* (attestation-gated release
  replacing a static Secret), not a real security guarantee. A production
  deployment needs real TEE hardware (SEV-SNP/TDX/etc.) and a policy that
  checks real measurements, plus a production Trustee deployment (TLS,
  HA, proper key management for the admin key).
