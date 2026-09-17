# Layer 3 KBS resource policy - PERMISSIVE, PoC/DEMO ONLY. DO NOT USE IN
# PRODUCTION.
#
# Real Trustee deployments gate resource release on actual TEE evidence
# (SEV-SNP/TDX measurements, etc.), and KBS's own default policy
# (kbs/config/kubernetes/base/policy.rego) explicitly DENIES releases when
# input["tee"] == "sample" - "sample" is the placeholder attester used
# when no confidential hardware is present, which is exactly what
# kata-qemu-coco-dev provides. This PoC needs the opposite: since there is
# no real confidential hardware to attest to, this policy explicitly
# ALLOWS release whenever the TEE type is "sample", which is equivalent
# to "always allow" in this environment.
#
# Any resource under any path is released as long as the caller's
# attestation evidence identifies as the "sample" TEE type. Loaded via
# 05-set-resource-policy.sh / kbs-client set-resource-policy.
package policy

default allow = false

allow {
	input["tee"] == "sample"
}
