# Layer 3 demo-only policy: denies every resource release, unconditionally.
#
# Used by layer3/scripts/demo-policy-deny.sh to prove the consumer aborts
# correctly when KBS refuses to release the key - the counterpart to
# resource-policy.rego (which allows release for the "sample" TEE type).
# Not used in the normal Layer 3 flow.
package policy

default allow = false
