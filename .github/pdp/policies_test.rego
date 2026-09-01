# Tests for tba.pdp.
#
# Every rule in policies.rego has a test that FAILS WITHOUT IT. That is the
# actual requirement -- a test that passes whether or not the rule exists is
# coverage, not evidence. Where a rule guards against a fail-OPEN shape (a
# missing count, an undefined helper), the test asserts the DENIAL, because that
# is the behaviour that would silently disappear.
package tba.pdp_test

import data.tba.pdp
import rego.v1

# A well-formed input that violates nothing. Every negative test below is this
# object with exactly one thing changed, so a failure names the change.
clean := {
	"image": {
		"pool": "Trusted-Build",
		"enforcement": "observe",
		"runsAsRoot": true,
		"runsAsRootReason": "kaniko chroot(2)s into the scratch root it unpacks the base image over; CAP_SYS_CHROOT only.",
		"tools": ["kaniko-executor", "envbuilder", "git", "bash"],
		"labels": {
			"org.opencontainers.image.source": "https://github.com/infrashift/trusted-build-agents",
			"org.opencontainers.image.revision": "0f6f2c1a0b3e4d5f60718293a4b5c6d7e8f90a1b",
			"org.opencontainers.image.version": "5.278.0",
			"io.infrashift.image.upstream.digest": "sha256:8073bce76a1842ce7559e6870f88b7473ff14d0ee2f0af0d49fe44749a17e4bf",
			"io.infrashift.image.upstream.source": "ghcr.io/infrashift/trusted-base-images/trusted/ubi9-minimal",
			"io.infrashift.agent.pool": "Trusted-Build",
		},
	},
	"scan": {"critical": 0, "fixable_high": 0},
	"contract": {
		"required": ["kaniko-executor", "envbuilder"],
		"forbidden": ["skopeo", "cosign"],
	},
}

test_clean_input_is_allowed if {
	pdp.allow_pipeline with input as clean
	count(pdp.violations) == 0 with input as clean
	pdp.route == "trusted" with input as clean
}

# --- the empty-input case, which is the whole point of default false ------

test_empty_input_is_denied if {
	not pdp.allow_pipeline with input as {}
}

test_empty_input_routes_to_quarantine if {
	pdp.route == "quarantine" with input as {}
}

# --- labels ---------------------------------------------------------------

test_missing_required_label_denies if {
	i := json.remove(clean, ["image/labels/org.opencontainers.image.source"])
	not pdp.allow_pipeline with input as i
	some v in pdp.violations with input as i
	startswith(v, "BUILD_LABEL_EMPTY")
}

# The real regression: the label KEY is present and the VALUE is empty, because
# an ARG was not re-declared after the runtime FROM. A presence check alone
# passes this input.
test_empty_label_value_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/labels/org.opencontainers.image.revision", "value": ""}])
	not pdp.allow_pipeline with input as i
}

# The regression this rule was written for: a fallback that appended a second
# line to a label which was otherwise perfectly present.
test_multiline_label_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/labels/org.opencontainers.image.revision", "value": "HEAD\nunknown"}])
	not pdp.allow_pipeline with input as i
	some v in pdp.violations with input as i
	startswith(v, "BUILD_LABEL_EMPTY")
}

test_whitespace_only_label_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/labels/org.opencontainers.image.version", "value": "   "}])
	not pdp.allow_pipeline with input as i
}

# --- CVE thresholds -------------------------------------------------------

test_critical_cve_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/scan/critical", "value": 2}])
	not pdp.allow_pipeline with input as i
}

test_fixable_high_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/scan/fixable_high", "value": 1}])
	not pdp.allow_pipeline with input as i
}

# THE FAIL-OPEN TEST. Without the is_number() guard and its companion rule, a
# scan report with no critical count makes `> 0` undefined, no rule fires, and
# the image is ALLOWED. Delete either half of that pair and this test fails.
test_missing_scan_count_denies if {
	i := json.remove(clean, ["scan/critical"])
	not pdp.allow_pipeline with input as i
	some v in pdp.violations with input as i
	startswith(v, "CVE_SCAN_MISSING")
}

test_non_numeric_scan_count_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/scan/critical", "value": "none"}])
	not pdp.allow_pipeline with input as i
}

# --- the capability contract ---------------------------------------------

test_forbidden_tool_present_denies if {
	i := json.patch(clean, [{"op": "add", "path": "/image/tools/-", "value": "skopeo"}])
	not pdp.allow_pipeline with input as i
	some v in pdp.violations with input as i
	v == "CONTRACT_BREACH: forbidden tool skopeo is present"
}

test_required_tool_absent_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/tools", "value": ["git", "bash"]}])
	not pdp.allow_pipeline with input as i
	some v in pdp.violations with input as i
	startswith(v, "CONTRACT_INCOMPLETE")
}

# The negation-direction test. If tool_is_absent were written as a bare
# `not tool_in_image(tool)` over an undefined helper, it would be true for every
# tool and this clean input would report every required tool as missing.
test_present_tools_do_not_report_absent if {
	every v in pdp.violations {
		not startswith(v, "CONTRACT_INCOMPLETE")
	} with input as clean
}

# --- configuration -------------------------------------------------------

test_pool_label_mismatch_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/labels/io.infrashift.agent.pool", "value": "Trusted-Publish"}])
	not pdp.allow_pipeline with input as i
}

# BOTH SIDES ABSENT MUST DENY. With one shared sentinel this input would compare
# equal to itself and pass -- which is precisely the case where nothing is known
# about which pool the image belongs to.
test_pool_absent_on_both_sides_denies if {
	i := json.remove(clean, ["image/pool", "image/labels/io.infrashift.agent.pool"])
	not pdp.allow_pipeline with input as i
	some v in pdp.violations with input as i
	startswith(v, "POOL_MISMATCH")
}

test_root_without_reason_denies if {
	i := json.remove(clean, ["image/runsAsRootReason"])
	not pdp.allow_pipeline with input as i
}

test_root_with_token_reason_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/runsAsRootReason", "value": "needed"}])
	not pdp.allow_pipeline with input as i
}

test_non_root_image_needs_no_reason if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/runsAsRoot", "value": false}])
	i2 := json.remove(i, ["image/runsAsRootReason"])
	pdp.allow_pipeline with input as i2
}

# --- enforcement ----------------------------------------------------------

test_unknown_enforcement_denies if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/enforcement", "value": "advisory"}])
	not pdp.allow_pipeline with input as i
}

test_missing_enforcement_denies if {
	i := json.remove(clean, ["image/enforcement"])
	not pdp.allow_pipeline with input as i
	pdp.enforcement == "<missing-enforcement>" with input as i
}

test_enforce_is_valid if {
	i := json.patch(clean, [{"op": "replace", "path": "/image/enforcement", "value": "enforce"}])
	pdp.allow_pipeline with input as i
	pdp.enforcement == "enforce" with input as i
}

# --- the decision document ------------------------------------------------

# observe still COMPUTES and RECORDS the violation and still routes to
# quarantine. It only stops the pipeline hard-failing. A change that made
# observe suppress violations would pass every test above and break this one.
test_observe_still_records_violations_and_quarantines if {
	i := json.patch(clean, [{"op": "replace", "path": "/scan/critical", "value": 3}])
	d := pdp.decision with input as i
	d.enforcement == "observe"
	d.route == "quarantine"
	count(d.violations) > 0
	d.allow == false
}
