#!/usr/bin/env bash
# Build one image for one architecture, resolving every pin from versions.json.
#
# THIS SCRIPT IS THE ONLY PLACE A PIN BECOMES A BUILD ARG. The Containerfiles
# name ARGs and never values; versions.json holds values and never build logic.
# That split is what makes `no hardcoded digests' checkable rather than merely
# stated -- lint-containerfiles.sh fails on a sha256: literal in a Containerfile,
# and there is nowhere else for one to hide.
#
# Usage: build-leg.sh <image> <arch>
set -euo pipefail

log() { printf '%s build-leg: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

IMAGE="${1:?usage: build-leg.sh <image> <arch>}"
ARCH="${2:?missing <arch>: amd64 or arm64}"

command -v buildah >/dev/null || fail "buildah is not installed"
command -v jq      >/dev/null || fail "jq is not installed"

V=versions.json
q() { jq -r "$1" "$V"; }

jq -e --arg i "$IMAGE" '.images | has($i)' "$V" >/dev/null \
  || fail "$IMAGE is not in versions.json"
jq -e --arg i "$IMAGE" --arg a "$ARCH" '.images[$i].arches | index($a)' "$V" >/dev/null \
  || fail "$IMAGE does not declare arch $ARCH"

CONTAINERFILE=$(q ".images[\"$IMAGE\"].containerfile")
BASE_KEY=$(q ".images[\"$IMAGE\"].base")
TC_KEY=$(q ".images[\"$IMAGE\"].toolchain")
AGENT_KEY=$(q ".images[\"$IMAGE\"].agent")

UPSTREAM_BASE=$(q ".bases[\"$BASE_KEY\"].image")
UPSTREAM_DIGEST=$(q ".bases[\"$BASE_KEY\"].amd64.digest")
[ "$ARCH" = arm64 ] && UPSTREAM_DIGEST=$(q ".bases[\"$BASE_KEY\"].arm64.digest")

TOOLCHAIN_BASE=$(q ".toolchains[\"$TC_KEY\"].image")
TOOLCHAIN_DIGEST=$(q ".toolchains[\"$TC_KEY\"].${ARCH}.digest")

AGENT_VERSION=$(q ".agents[\"$AGENT_KEY\"].version")
AGENT_ARCH=$(q ".agents[\"$AGENT_KEY\"].${ARCH}.arch")
AGENT_SHA256=$(q ".agents[\"$AGENT_KEY\"].${ARCH}.sha256")
AGENT_URL=$(q ".agents[\"$AGENT_KEY\"].urlTemplate" \
  | sed -e "s|\${VERSION}|${AGENT_VERSION}|g" -e "s|\${ARCH}|${AGENT_ARCH}|g")

# --verify is load-bearing. Plain `git rev-parse HEAD' in a repository with no
# commits prints "HEAD" to STDOUT and then fails, so `|| echo unknown' appends a
# second line and the label becomes the two-line string "HEAD\nunknown".
# --verify fails without emitting anything, which is what the fallback needs.
GIT_COMMIT=$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)
SOURCE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/infrashift/trusted-build-agents")
# A build date that moves is fine here -- it is metadata, not a pin -- but it is
# taken once so both the label and the manifest agree.
BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

ARGS=(
  --build-arg "UPSTREAM_BASE=${UPSTREAM_BASE}"
  --build-arg "UPSTREAM_DIGEST=${UPSTREAM_DIGEST}"
  --build-arg "TOOLCHAIN_BASE=${TOOLCHAIN_BASE}"
  --build-arg "TOOLCHAIN_DIGEST=${TOOLCHAIN_DIGEST}"
  --build-arg "AGENT_URL=${AGENT_URL}"
  --build-arg "AGENT_SHA256=${AGENT_SHA256}"
  --build-arg "AGENT_VERSION=${AGENT_VERSION}"
  --build-arg "SOURCE_URL=${SOURCE_URL}"
  --build-arg "IMAGE_VERSION=${AGENT_VERSION}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "GIT_COMMIT=${GIT_COMMIT}"
  --build-arg "TARGETARCH=${ARCH}"
)

# Each Go tool contributes a URL and a COMMIT arg named after itself, so adding a
# tool to versions.json needs no edit here.
while read -r tool; do
  [ -n "$tool" ] || continue
  upper=$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')
  ARGS+=( --build-arg "${upper}_URL=$(q ".sources[\"$tool\"].url")" )
  ARGS+=( --build-arg "${upper}_COMMIT=$(q ".sources[\"$tool\"].commit")" )
  # The REF is what gets stamped into the binary's version string, matching
  # containerfiles/versions.lock in the sshadowforge forge exactly -- so the
  # kaniko here and the kaniko there report the same version. The COMMIT is what
  # the fetch is asserted against, because a tag can be moved and a commit cannot.
  ARGS+=( --build-arg "${upper}_REF=$(q ".sources[\"$tool\"].ref")" )
done < <(jq -r --arg i "$IMAGE" '.images[$i].goTools[]' "$V")

REGISTRY="${REGISTRY:-ghcr.io/infrashift/trusted-build-agents}"
TAG="${TAG:-dev-${ARCH}}"
REF="${REGISTRY}/development/${IMAGE}:${TAG}"

# --layers is OPT-IN via BUILDAH_LAYERS=1, for local iteration: the two Go stages
# take about ten minutes and almost never change. It is left off by default
# because CI runners are ephemeral -- there is no cache to hit there, and a
# cache that only ever exists on a developer's laptop is a difference between
# what they test and what CI builds.
LAYERS=()
[ -n "${BUILDAH_LAYERS:-}" ] && LAYERS=(--layers)

log "building $REF for linux/$ARCH from $CONTAINERFILE"
buildah bud \
  --platform "linux/${ARCH}" \
  "${LAYERS[@]}" \
  "${ARGS[@]}" \
  -t "$REF" \
  -f "$CONTAINERFILE" .

log "built $REF"
printf '%s\n' "$REF"
