#!/usr/bin/env bash
# Assert the capability boundary described in image-contract.json.
#
# TWO MODES, and the source mode is the stronger one.
#
#   (default)        checks the rootfs SCRIPTS. Flavour-independent, runs in
#                    seconds, and fails on the LINE that would have broken rather
#                    than on the image that happened to expose it.
#
#   --image <ref>    checks a BUILT image with `podman run`. This is the one that
#                    catches a tool arriving as a transitive dependency, which no
#                    amount of reading the Containerfile can find: microdnf
#                    resolves a dependency CLOSURE, so "the build agent cannot
#                    reach a registry" stays true only until something drags
#                    skopeo in and nothing notices.
#
# Adapted from containerfiles/stage-contract.json and roles/verify in the
# sshadowforge forge.
set -euo pipefail

MODE=source
IMAGE_NAME=""
IMAGE_REF=""
if [ "${1:-}" = "--image" ]; then
  MODE=image
  IMAGE_NAME="${2:?usage: lint-image-contract.sh --image <name> <ref>}"
  IMAGE_REF="${3:?usage: lint-image-contract.sh --image <name> <ref>}"
fi

if [ "$MODE" = source ]; then
  python3 - <<'PY'
import json, re, sys

C = json.load(open('image-contract.json'))
V = json.load(open('versions.json'))
fail = []
def err(m): fail.append(m)

# --- The shared scripts must not REACH for a forbidden tool ---------------
# This is checked on EVERY script regardless of which image carries it. A build
# script that shelled out to skopeo would fail on the build agent (no skopeo) but
# would work on the publish agent, so the bug would only appear where it does the
# most damage.
for path in C['scripts_checked']:
    try:
        text = open(path).read()
    except FileNotFoundError:
        err(f"{path}: listed in scripts_checked but missing on disk")
        continue
    # Strip comments: these scripts explain at length why they do NOT use skopeo,
    # and a naive scan would fail on the explanation.
    code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
    for tool in C['scripts_must_not_invoke']:
        for form in (f"{tool} ", f"{tool}\n", f"`{tool}`", f"$({tool}"):
            if form in code:
                err(f"{path}: invokes {tool!r}, which scripts_must_not_invoke forbids")
                break

# --- Per-script assertions ------------------------------------------------
for path, rules in C['script_assertions'].items():
    try:
        text = open(path).read()
    except FileNotFoundError:
        err(f"{path}: named in script_assertions but missing on disk")
        continue
    code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
    # REGEXES, not substrings. `--no-push' as a plain substring is satisfied by
    # `--no-push-cache' two lines below it, so deleting the real flag left the
    # assertion passing -- found by scripts/selftest-linters.sh, which is the
    # entire reason that script exists.
    for pat in rules.get('must_match', []):
        if not re.search(pat, code):
            err(f"{path}: must match /{pat}/ and does not")
    for pat in rules.get('must_not_match', []):
        if re.search(pat, code):
            err(f"{path}: must NOT match /{pat}/ and does")

# --- Every required script is actually COPYed into its image --------------
# A contract that names a script the Containerfile never installs asserts
# nothing: the image-mode check would fail at run time, long after the PR.
for name, spec in C['images'].items():
    cf = V['images'][name]['containerfile']
    text = open(cf).read()
    for req in spec['required']:
        if req.endswith('.sh') and 'rootfs/' not in text:
            err(f"{cf}: contract requires {req!r} but the Containerfile COPYs no rootfs/")
    if spec['entrypoint'] != V['images'][name]['runtime']['entrypoint']:
        err(f"image-contract.json: {name} entrypoint {spec['entrypoint']} disagrees with "
            f"versions.json runtime.entrypoint {V['images'][name]['runtime']['entrypoint']}")

if fail:
    for m in fail:
        print(f"error: {m}", file=sys.stderr)
    print(f"\n{len(fail)} contract issue(s)", file=sys.stderr)
    sys.exit(1)
print(f"OK: {len(C['scripts_checked'])} scripts and {len(C['images'])} image contracts pass source checks")
PY
  exit 0
fi

# --- image mode -----------------------------------------------------------
RUN="${CONTRACT_RUNNER:-podman}"
required="$(jq -r --arg n "$IMAGE_NAME" '.images[$n].required[]' image-contract.json)"
forbidden="$(jq -r --arg n "$IMAGE_NAME" '.images[$n].forbidden[]' image-contract.json)"
floor="$(jq -r '.floor_required[]' image-contract.json)"

rc=0
for tool in $floor $required; do
  if ! "$RUN" run --rm --entrypoint /bin/bash "$IMAGE_REF" -c "command -v '$tool' >/dev/null"; then
    echo "error: $IMAGE_NAME: required tool '$tool' is MISSING" >&2
    rc=1
  fi
done
for tool in $forbidden; do
  if "$RUN" run --rm --entrypoint /bin/bash "$IMAGE_REF" -c "command -v '$tool' >/dev/null"; then
    echo "error: $IMAGE_NAME: forbidden tool '$tool' is PRESENT -- the capability boundary has been breached, most likely by a transitive dependency" >&2
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo "OK: $IMAGE_NAME satisfies its contract"
fi
exit "$rc"
