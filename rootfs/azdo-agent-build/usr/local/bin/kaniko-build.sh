#!/usr/bin/env bash
# Build an OCI image from a Containerfile and STAGE it as an OCI layout.
#
# STAGES. DOES NOT PUSH, and the flag is not the reason -- the reason is that
# this image contains no registry client at all. kaniko is perfectly capable of
# pushing, which is what --destination is for, and this script must never let it:
# --no-push is a literal, so no pipeline variable can turn it back on. The layout
# is collected as a pipeline artifact and pushed by a job in the Trusted-Publish
# pool, holding a Nexus credential that no repository and no build job has.
#
# Usage: kaniko-build.sh <context-dir> <containerfile> <image-ref> <out-dir>
set -euo pipefail

log() { printf '%s kaniko-build: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

CONTEXT="${1:?usage: kaniko-build.sh <context-dir> <containerfile> <image-ref> <out-dir>}"
CONTAINERFILE="${2:?missing <containerfile>, relative to the context}"
REF="${3:?missing <image-ref>, e.g. myapp:1.2.3}"
OUTDIR="${4:?missing <out-dir>}"

KROOT="${SFD_KANIKO_ROOT:-/azp/kaniko}"

[ -d "$CONTEXT" ] || fail "context directory $CONTEXT does not exist"
[ -f "$CONTEXT/$CONTAINERFILE" ] || fail "no $CONTAINERFILE at the root of $CONTEXT"

kaniko-chroot.sh

# THE CONTEXT IS COPIED IN, NOT BIND-MOUNTED. A bind mount needs CAP_SYS_ADMIN,
# which is the one privilege this whole design exists to avoid.
log "staging the build context into the chroot"
rm -rf "${KROOT:?}/ctx"
mkdir -p "$KROOT/ctx"
cp -a "$CONTEXT/." "$KROOT/ctx/" || fail "could not stage the build context"

# A TIMESTAMP THAT MOVES is the single most common reason two builds of one
# revision disagree. Prefer the commit date; fall back to a fixed epoch, never to
# the clock. Build.SourceVersion is set by Azure Pipelines on every checkout.
if [ -z "${SOURCE_DATE_EPOCH:-}" ] && [ -n "${BUILD_SOURCEVERSION:-}" ] && [ -d "$CONTEXT/.git" ]; then
  SOURCE_DATE_EPOCH="$(git -C "$CONTEXT" show -s --format=%ct "$BUILD_SOURCEVERSION" 2>/dev/null || echo 0)"
fi
: "${SOURCE_DATE_EPOCH:=0}"
export SOURCE_DATE_EPOCH
log "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

# THE FLAGS, and why each one is here. Ported from golden/scripts/image.sh.
#
#   --force             REQUIRED, and not a loosening. kaniko refuses to run
#                       unless it believes it is in a container, and it decides
#                       that by reading /proc/self/cgroup and
#                       /proc/self/mountinfo -- which inside the chroot are the
#                       deliberate stubs in docs/kaniko-chroot.md. The EMPTY
#                       mountinfo is required for the ignore list, so the
#                       detection cannot be satisfied without breaking the thing
#                       it exists to serve. We are in a container; kaniko simply
#                       cannot see it from in here. Without this the build dies
#                       with "kaniko should only be run inside of a container".
#   --no-push           unconditional; see the header.
#   --destination       kaniko needs a NAME for the image it assembles even when
#                       it is not pushing it. This is not a push target.
#   --oci-layout-path   NOT --tar-path, which writes a *docker* tarball. The
#                       artifact has to be an OCI layout: the publish job copies
#                       it to the registry with skopeo, and a format conversion
#                       on the way would change the digest between what was
#                       scanned and what lands there.
#   --cache --cache-dir the warmed base images. The base cache only works with
#                       --cache=true, which in turn REFUSES TO START under
#                       --no-push unless a --cache-repo is named.
#   --cache-repo oci:   the `oci:' prefix makes it a local path. Without it
#                       kaniko runs a push-permission check against the name and
#                       fails blaming a registry nobody asked for.
#   --reproducible      zeroes layer timestamps and history. Memory-hungry: it
#                       rewrites layers in memory.
#   --ignore-path x4    the scratch directories inside the chroot. Without them
#                       kaniko deletes the context on the way in and snapshots
#                       its own cache into the image.
log "building $REF"
# SSL_CERT_FILE points at the bundle kaniko-chroot.sh staged outside /etc, so it
# survives the sweep without sparing the base image's own trust store.
USER=root HOME=/tmp SSL_CERT_FILE=/kaniko-certs/tls-ca-bundle.pem \
  chroot "$KROOT" /kaniko/executor \
  --context "dir:///ctx" \
  --dockerfile "/ctx/$CONTAINERFILE" \
  --destination "$REF" \
  --no-push \
  --force \
  --oci-layout-path /out/image \
  --digest-file /out/image.digest \
  --cache=true \
  --cache-dir /cache \
  --cache-repo oci:/layercache \
  --no-push-cache \
  --reproducible \
  --custom-platform "${SFD_PLATFORM:-linux/amd64}" \
  --ignore-path /ctx \
  --ignore-path /cache \
  --ignore-path /out \
  --ignore-path /layercache \
  --ignore-path /kaniko-certs \
  --ignore-path /etc/resolv.conf \
  --ignore-path /etc/hosts \
  --verbosity "${SFD_KANIKO_VERBOSITY:-info}"

mkdir -p "$OUTDIR"
cp -a "$KROOT/out/image" "$OUTDIR/image"
cp -a "$KROOT/out/image.digest" "$OUTDIR/image.digest"

log "staged OCI layout at $OUTDIR/image ($(cat "$OUTDIR/image.digest"))"
