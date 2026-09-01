# Policy Decision Point for trusted-build-agents.
#
# THE FAIL-CLOSED CONTRACT. Five rules, each of which exists because breaking it
# produces a policy that PASSES while checking nothing. That failure mode is not
# theoretical -- the sibling repos shipped three lint rules that passed by
# matching their own comments, and a crosscheck that reported a MATCH by
# comparing two empty strings.
#
#   1. `> 0` against a MISSING value is UNDEFINED in Rego, i.e. silently
#      non-violating. Every numeric field gets an is_number() guard, and a
#      separate rule fires when the guard fails -- a missing scan is not a clean
#      scan.
#   2. Every enum is read via object.get() with a "<missing>" sentinel against a
#      closed set. Unknown or absent violates.
#   3. When two fields must match, each side gets a DIFFERENT sentinel default,
#      so "both absent" compares unequal and denies.
#   4. Never write `not <thing_is_bad>` -- an undefined helper makes `not` true,
#      which fails open. Define the positive predicate and negate that.
#   5. Every new rule needs a test that fails without it. Coverage floor is 85%.
#
# VIOLATIONS ARE A PARTIAL SET, NOT A COMPLETE RULE. Two complete rules that both
# produce a value for the same input CONFLICT at evaluation time, and the
# conflict surfaces as an evaluation error rather than a verdict -- which a
# pipeline that only reads `allow_pipeline` would see as "no answer" rather than
# "deny". Partial sets merge. This is the shape to keep.
#
# When you add a check, BREAK IT DELIBERATELY and confirm it fails.
package tba.pdp

import rego.v1

# --- entrypoints ----------------------------------------------------------

# The gate. Default false: an input this policy cannot understand is denied.
default allow_pipeline := false

allow_pipeline if count(violations) == 0

# The full decision, for the evidence bundle. Always computed, even in observe
# mode -- `observe` stops the pipeline hard-failing, it does not stop the
# violations being recorded or the image being routed to quarantine.
decision := {
	"allow": allow_pipeline,
	"enforcement": enforcement,
	"route": route,
	"violations": violations,
}

valid_enforcement := {"enforce", "observe"}

enforcement := e if {
	e := object.get(input, ["image", "enforcement"], "<missing-enforcement>")
	valid_enforcement[e]
} else := "<missing-enforcement>"

route := "trusted" if count(violations) == 0

route := "quarantine" if count(violations) > 0

# --- labels ---------------------------------------------------------------

required_labels := {
	"org.opencontainers.image.source",
	"org.opencontainers.image.revision",
	"org.opencontainers.image.version",
	"io.infrashift.image.upstream.digest",
	"io.infrashift.image.upstream.source",
}

# BUILD_LABEL_EMPTY. ARGs declared before the first FROM are global build args
# and are NOT in scope inside a stage, so a Containerfile that forgets to
# re-declare them produces labels that expand to the empty string. The image
# still builds and still looks labelled. This is the rule that catches it.
violations contains msg if {
	some key in required_labels
	value := object.get(input, ["image", "labels", key], "<missing-label>")
	label_is_unusable(value)
	msg := sprintf("BUILD_LABEL_EMPTY: required label %v is missing or empty", [key])
}

label_is_unusable(value) if value == "<missing-label>"

label_is_unusable(value) if {
	is_string(value)
	trim_space(value) == ""
}

# A MULTI-LINE LABEL IS MALFORMED, and this rule exists because the empty check
# alone did not catch a real one. `git rev-parse HEAD' in a repository with no
# commits prints "HEAD" to stdout AND fails, so a `|| echo unknown' fallback
# produced the two-line revision label "HEAD\nunknown". Non-empty, present, and
# useless -- which is the shape the empty check was never going to find.
label_is_unusable(value) if {
	is_string(value)
	contains(value, "\n")
}

# --- CVE thresholds -------------------------------------------------------

# is_number() is the guard. Without it, a scan report missing `critical` makes
# `> 0` undefined, the rule does not fire, and a missing scan reads as a clean
# one -- the single most dangerous shape a security gate can have. The companion
# rule below is what turns that silence into a denial.
violations contains msg if {
	n := object.get(input, ["scan", "critical"], "<missing-count>")
	is_number(n)
	n > 0
	msg := sprintf("CVE_CRITICAL: %v critical vulnerabilities", [n])
}

violations contains msg if {
	n := object.get(input, ["scan", "critical"], "<missing-count>")
	not is_number(n)
	msg := "CVE_SCAN_MISSING: no critical count in the scan report; a missing scan is not a clean scan"
}

violations contains msg if {
	n := object.get(input, ["scan", "fixable_high"], "<missing-count>")
	is_number(n)
	n > 0
	msg := sprintf("CVE_FIXABLE_HIGH: %v high vulnerabilities with an upstream fix available", [n])
}

# --- the capability contract ---------------------------------------------

# CONTRACT_BREACH. image-contract.json says what each image must not contain;
# this is the same assertion at policy time, against the tool inventory the build
# reported. A forbidden tool arriving as a transitive dependency is the thing
# neither the Containerfile nor a human review would catch.
violations contains msg if {
	some tool in object.get(input, ["contract", "forbidden"], [])
	tool in object.get(input, ["image", "tools"], [])
	msg := sprintf("CONTRACT_BREACH: forbidden tool %v is present", [tool])
}

violations contains msg if {
	some tool in object.get(input, ["contract", "required"], [])
	tool_is_absent(tool)
	msg := sprintf("CONTRACT_INCOMPLETE: required tool %v is absent", [tool])
}

# Rule 4 of the contract: define the POSITIVE predicate and negate THAT. Writing
# `not tool_in_image(tool)` against an undefined helper would be true for every
# tool, and the rule would fire on a perfectly good image -- or, with the
# negation the other way round, on none.
tool_is_absent(tool) if {
	tools := object.get(input, ["image", "tools"], [])
	is_array(tools)
	not tool in tools
}

# --- configuration -------------------------------------------------------

# POOL_MISMATCH. In Azure DevOps a job chooses a POOL, not an image, so the pool
# is how the capability boundary is actually enforced at pipeline time. The two
# sides get DIFFERENT sentinels on purpose: with one shared default, an image
# carrying neither value would compare equal to itself and pass.
violations contains msg if {
	declared := object.get(input, ["image", "pool"], "<missing-declared-pool>")
	labelled := object.get(input, ["image", "labels", "io.infrashift.agent.pool"], "<missing-labelled-pool>")
	declared != labelled
	msg := sprintf("POOL_MISMATCH: versions.json declares pool %v, the image is labelled %v", [declared, labelled])
}

# ROOT_WITHOUT_REASON. Running as container-root is a real exemption -- kaniko
# needs CAP_SYS_CHROOT -- and an exemption with no written reason is a drift
# nobody can review. The length floor is deliberate: "needed" is not a reason.
violations contains msg if {
	object.get(input, ["image", "runsAsRoot"], false) == true
	reason := object.get(input, ["image", "runsAsRootReason"], "")
	count(reason) < 40
	msg := "ROOT_WITHOUT_REASON: runsAsRoot is set without a substantive runsAsRootReason"
}

# UNKNOWN_ENFORCEMENT. Closed set, sentinel default. An entry whose enforcement
# is absent or misspelled must not be treated as `observe` by accident.
violations contains msg if {
	e := object.get(input, ["image", "enforcement"], "<missing-enforcement>")
	not valid_enforcement[e]
	msg := sprintf("UNKNOWN_ENFORCEMENT: %v is not one of enforce, observe", [e])
}
