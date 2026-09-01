#!/usr/bin/env bash
# Prove the linters detect what they claim to detect.
#
# WHY THIS EXISTS. A check that has never failed is not a check, it is a
# decoration. The sibling repo shipped three lint rules that passed by matching
# their own comments and a crosscheck that reported a MATCH by comparing two
# empty strings -- all of which were green, continuously, for as long as nobody
# looked.
#
# So: apply a known-bad mutation to a COPY of the tree, run the linter that is
# supposed to object, and fail if it does not. Each case names the real bug it
# stands for.
# shellcheck disable=SC2016
# The sed and printf patterns below deliberately contain literal ${...} and
# backticks: they match build ARGs inside a Containerfile and backticked paths
# inside Markdown. Expanding them here would defeat the mutation.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# One mutation per case, applied to a fresh copy. `sed -i' on the real tree would
# leave it damaged if a case aborted.
case_fails() {
  local name="$1" linter="$2"; shift 2
  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $work now, not at trap time
  trap "rm -rf '$work'" RETURN
  cp -a "$REPO/." "$work/"
  rm -rf "$work/.git"
  ( cd "$work" && "$@" ) || { echo "  FAIL $name -- the mutation command errored"; FAIL=$((FAIL + 1)); return; }
  # A MUTATION THAT DID NOTHING would report as a linter miss and send you
  # looking in entirely the wrong place. `sed' with no match exits 0, which is
  # exactly how the --no-push case hid an over-escaped pattern for a while.
  if diff -rq "$REPO" "$work" -x .git >/dev/null 2>&1; then
    echo "  FAIL $name -- the mutation changed nothing; the test is vacuous"
    FAIL=$((FAIL + 1))
    return
  fi
  if ( cd "$work" && bash "$linter" >/dev/null 2>&1 ); then
    echo "  FAIL $name -- $linter PASSED on input it should reject"
    FAIL=$((FAIL + 1))
  else
    echo "  ok   $name"
    PASS=$((PASS + 1))
  fi
}

echo "lint-containerfiles.sh:"

# The bug both sibling repos actually shipped: ARGs declared only before the
# first FROM are out of scope inside the stage, so the LABELs expand to empty
# strings and the image looks labelled while carrying nothing.
case_fails "un-re-declared ARG after runtime FROM" scripts/lint-containerfiles.sh \
  sed -i '0,/^ARG UPSTREAM_DIGEST$/! {/^ARG UPSTREAM_DIGEST$/d}' Containerfiles/azdo-agent-build.Containerfile

# versions.json must be the only place a digest lives.
case_fails "hardcoded digest in a Containerfile" scripts/lint-containerfiles.sh \
  sed -i 's|^FROM ${UPSTREAM_BASE}@${UPSTREAM_DIGEST}$|FROM registry.example.com/x@sha256:0000000000000000000000000000000000000000000000000000000000000000|' Containerfiles/azdo-agent-build.Containerfile

# A moved tag fetched shallowly succeeds quietly; the rev-parse assertion is the
# only thing that catches it.
case_fails "missing commit assertion for a Go tool" scripts/lint-containerfiles.sh \
  sed -i '/rev-parse HEAD)" = "${KANIKO_COMMIT}"/d' Containerfiles/azdo-agent-build.Containerfile

# USER 1001 must be the LAST instruction; anything after it runs as root.
case_fails "instruction after USER 1001" scripts/lint-containerfiles.sh \
  sh -c 'printf "\nRUN true\n" >> Containerfiles/azdo-agent-build.Containerfile'

# An agent listens on nothing. An EXPOSE would be a claim that is not true.
case_fails "EXPOSE on an agent image" scripts/lint-containerfiles.sh \
  sh -c 'sed -i "s|^ENTRYPOINT|EXPOSE 8080\nENTRYPOINT|" Containerfiles/azdo-agent-build.Containerfile'

# Verifying after unpacking means a bad archive was already on disk.
case_fails "tarball unpacked before its hash is checked" scripts/lint-containerfiles.sh \
  python3 -c "
import re
p='Containerfiles/azdo-agent-build.Containerfile'
s=open(p).read()
s=s.replace('''    echo \"\${AGENT_SHA256}  /tmp/agent.tar.gz\" | sha256sum -c -; \\\\
    mkdir -p /out/agent; \\\\
    tar -C /out/agent -xzf /tmp/agent.tar.gz; \\\\''','''    mkdir -p /out/agent; \\\\
    tar -C /out/agent -xzf /tmp/agent.tar.gz; \\\\
    echo \"\${AGENT_SHA256}  /tmp/agent.tar.gz\" | sha256sum -c -; \\\\''')
open(p,'w').write(s)
"

echo "validate-schema.py:"

# A version bump that left the track behind. The track is the reviewed statement
# of where a pin may move; a ref outside it is a policy change nobody approved.
case_fails "pin drifted outside its own track" "scripts/validate-schema.py" \
  python3 -c "
import json
v=json.load(open('versions.json')); v['sources']['kaniko']['ref']='v2.0.0'
json.dump(v,open('versions.json','w'),indent=2)
"

# Two images in one pool means a job asking for that pool gets whichever agent
# registered first, and the build/publish split stops being a split.
case_fails "two images sharing one ADO pool" "scripts/validate-schema.py" \
  python3 -c "
import json
v=json.load(open('versions.json')); v['images']['azdo-agent-publish']['pool']='Trusted-Build'
json.dump(v,open('versions.json','w'),indent=2)
"

# An exemption with no written reason is a drift nobody can review.
case_fails "runsAsRoot without a reason" "scripts/validate-schema.py" \
  python3 -c "
import json
v=json.load(open('versions.json')); del v['images']['azdo-agent-build']['runtime']['runsAsRootReason']
json.dump(v,open('versions.json','w'),indent=2)
"

echo "lint-image-contract.sh:"

# The whole point of the split: the task holding repository code must not be able
# to reach a registry.
case_fails "build script reaching for skopeo" scripts/lint-image-contract.sh \
  sh -c 'printf "\nskopeo copy oci:/out docker://example.com/x:1\n" >> rootfs/azdo-agent-build/usr/local/bin/kaniko-build.sh'

# --no-push is the discipline. Removing it leaves only the absent binary.
case_fails "kaniko-build.sh losing --no-push" scripts/lint-image-contract.sh \
  sed -i '/^  --no-push \\$/d' rootfs/azdo-agent-build/usr/local/bin/kaniko-build.sh

# Naming a remote cache repo reintroduces the credential the split removes.
case_fails "envbuilder pointed at a remote cache repo" scripts/lint-image-contract.sh \
  sh -c 'printf "\nENVBUILDER_CACHE_REPO=nexus.example.com/oci/cache\n" >> rootfs/azdo-agent-build/usr/local/bin/envbuilder-build.sh'

# THE EMPTY-LAYER BUG. Staging the executor at the chroot root makes kaniko's
# working directory `/', which it then adds to its own ignore list -- so it
# ignores the entire filesystem and every layer comes out empty. The build still
# succeeds and still reports a digest, which is why nothing else here would catch
# it.
case_fails "kaniko executor staged at the chroot root" scripts/lint-image-contract.sh \
  sed -i 's|\$KROOT/kaniko/executor|$KROOT/kaniko-executor|; s|/kaniko/executor "\$KROOT/proc/self/exe"|/kaniko-executor "$KROOT/proc/self/exe"|' \
    rootfs/azdo-agent-build/usr/local/bin/kaniko-chroot.sh

# envbuilder refuses to let the embedded kaniko delete anything unless KANIKO_DIR
# is its working directory. That check is what stands between a misconfigured run
# and a wiped filesystem, so losing it must not be silent.
case_fails "envbuilder losing its KANIKO_DIR guard" scripts/lint-image-contract.sh \
  sed -i '/KANIKO_DIR=\/\.envbuilder/d' rootfs/azdo-agent-build/usr/local/bin/envbuilder-build.sh

# FORCE_SAFE=true disables that same check. There is no legitimate reason to set
# it here: the chroot is what makes the deletion safe, not a bypass.
case_fails "envbuilder bypassing the safety check" scripts/lint-image-contract.sh \
  sh -c 'printf "\n  FORCE_SAFE=true \\\n" >> rootfs/azdo-agent-build/usr/local/bin/envbuilder-build.sh'

# The cache-repo placeholder must stay loopback. A plausible-looking hostname
# here is what turns "the override stopped happening" from a loud failure into a
# push at a real registry.
case_fails "envbuilder cache placeholder pointed off-box" scripts/lint-image-contract.sh \
  sed -i 's|CACHE_PLACEHOLDER="localhost:1/|CACHE_PLACEHOLDER="nexus.example.com/|' \
    rootfs/azdo-agent-build/usr/local/bin/envbuilder-build.sh

echo "scan-secrets.sh:"

# A scanner that has never fired is indistinguishable from one that cannot.
#
# THE FIXTURE VALUES ARE BUILT AT RUNTIME, never written literally. Spelling a
# credential-shaped string into this file makes the scanner fire on its own test
# -- which is how a repository ends up allowlisting the file that proves the
# scanner works, and losing the proof.
case_fails "a real-looking Nexus client secret in a script" scripts/scan-secrets.sh \
  sh -c 'v=$(printf "k%.0s" $(seq 28)); printf "\nSFD_OCI_CLIENT_SECRET=%s\n" "$v" >> rootfs/azdo-agent-publish/usr/local/bin/push-oci.sh'

# And an Azure DevOps PAT, which is the secret this repository is most likely to
# meet: the agent registers with one.
case_fails "an Azure DevOps PAT pasted into a template" scripts/scan-secrets.sh \
  sh -c 'v=$(printf "a%.0s" $(seq 52)); printf "\nAZP_TOKEN=%s\n" "$v" >> rootfs/common/usr/local/bin/start-agent.sh'

echo "lint-docs.sh:"

case_fails "document naming a file that does not exist" scripts/lint-docs.sh \
  sh -c 'printf "\nSee \`scripts/does-not-exist.sh\` for details.\n" >> README.md'

echo
echo "selftest: $PASS detected, $FAIL missed"
[ "$FAIL" -eq 0 ] || exit 1
