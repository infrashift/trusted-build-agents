#!/usr/bin/env bash
# Build a devcontainer image from a devcontainer.json and STAGE it for publish.
#
# READ docs/envbuilder-output.md BEFORE CHANGING ANY OF THIS. envbuilder is not a
# drop-in image builder and three of its behaviours are load-bearing here:
#
#   1. envbuilder UNPACKS THE BASE IMAGE INTO ITS OWN `/', exactly as kaniko does
#      -- it embeds kaniko as a library. Run directly on the agent it would sweep
#      the agent's own filesystem out from under the job that is running it. So
#      it runs in the SAME chroot kaniko does, prepared by kaniko-chroot.sh.
#
#   2. envbuilder HAS NO --no-push. Producing a distributable image requires
#      ENVBUILDER_PUSH_IMAGE=true and a cache repo. Setting
#      ENVBUILDER_LAYER_CACHE_DIR makes envbuilder start its OWN in-process
#      registry over that directory and override the cache repo with
#      `localhost:<port>/local/cache' (envbuilder.go:384-394, 1863-1909). The
#      push therefore goes to loopback and needs no credential -- which is how
#      this script keeps the no-credential property that kaniko-build.sh gets
#      from --no-push.
#
#   3. envbuilder EXECS INTO THE BUILT ENVIRONMENT when it finishes; it is
#      designed to be a container's PID 1. ENVBUILDER_INIT_SCRIPT makes that exec
#      a no-op so the build returns to the pipeline instead of hanging.
#
# --get-cached-image is a DRY RUN (RunCacheProbe sets NoPush: true), so it cannot
# be used to produce the image -- only to read back the digest of one already in
# the cache. Hence two invocations: build, then probe for the digest.
#
# Usage: envbuilder-build.sh <workspace-dir> <out-dir>
set -euo pipefail

log() { printf '%s envbuilder-build: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

WORKSPACE="${1:?usage: envbuilder-build.sh <workspace-dir> <out-dir>}"
OUTDIR="${2:?missing <out-dir>}"

KROOT="${SFD_KANIKO_ROOT:-/azp/kaniko}"
CACHE_IN_ROOT="/layercache"

[ -d "$WORKSPACE" ] || fail "workspace directory $WORKSPACE does not exist"
command -v envbuilder >/dev/null 2>&1 \
  || fail "envbuilder is not on PATH. This script runs in the Trusted-Build pool, which is the only pool whose image carries it."

kaniko-chroot.sh

# ENVBUILDER LIVES AT ITS OWN DEFAULT PATH, NOT ALONGSIDE THE KANIKO EXECUTOR.
#
# envbuilder carries a safety check of its own: before it lets the embedded
# kaniko delete the filesystem, it asserts KANIKO_DIR is its working directory,
# and bails with
#   KANIKO_DIR is not set to /.envbuilder. Bailing!
#   To bypass this check, set FORCE_SAFE=true.
# That check exists to stop envbuilder wiping a real system when it is run
# somewhere it was not meant to be, so it is SATISFIED here, never bypassed --
# FORCE_SAFE would disable exactly the protection the chroot exists to make
# unnecessary, on the one code path that deletes things.
#
# Satisfying it means using envbuilder's own layout: the binary at its default
# BinaryPath (/.envbuilder/bin/envbuilder, options/defaults.go:69) and
# KANIKO_DIR=/.envbuilder to match. proc/self/exe points at the RUNNING binary,
# so the kaniko library inside envbuilder derives its ignore directory from the
# same place -- the same rule as the executor, applied to a different binary.
mkdir -p "$KROOT/.envbuilder/bin"
cp "$(command -v envbuilder)" "$KROOT/.envbuilder/bin/envbuilder" \
  || fail "could not stage envbuilder into $KROOT/.envbuilder/bin"
ln -sf /.envbuilder/bin/envbuilder "$KROOT/proc/self/exe"

log "staging the workspace into the chroot"
rm -rf "${KROOT:?}/workspace"
mkdir -p "$KROOT/workspace"
cp -a "$WORKSPACE/." "$KROOT/workspace/" || fail "could not stage the workspace"

: "${SOURCE_DATE_EPOCH:=0}"
export SOURCE_DATE_EPOCH

# ENVBUILDER_CACHE_REPO MUST BE SET, AND IS THEN IGNORED. This reads wrong and is
# correct, and the ordering in envbuilder is the whole reason:
#
#   envbuilder.go:141  if opts.CacheRepo == "" && opts.PushImage { return error }
#   envbuilder.go:386  "Overriding cache repo with local registry..."
#
# The GUARD runs before the OVERRIDE. So setting only ENVBUILDER_LAYER_CACHE_DIR
# -- which is what actually redirects the push to loopback -- dies at the guard
# with `--cache-repo must be set when using --push-image', never reaching the
# line that would have made the cache repo unnecessary.
#
# The value below is therefore a placeholder that exists only to satisfy line
# 141, and it is chosen to FAIL CLOSED: port 1 refuses connections, so if the
# override at line 386 ever stops happening, the push fails loudly instead of
# quietly reaching a real registry. A plausible-looking hostname here would be
# the dangerous choice.
CACHE_PLACEHOLDER="localhost:1/envbuilder-cache-placeholder"

# ENVBUILDER_IGNORE_PATHS -- what must SURVIVE the sweep.
#
# envbuilder deletes the filesystem as its own stage #0, BEFORE the embedded
# kaniko initialises. So anything kaniko needs afterwards has to be protected
# here, not by kaniko's --ignore-path. Losing the /proc stub this way produces
#   do build: failed to initialize ignore list: checking filesystem mount paths
#   for ignore list: open /proc/self/mountinfo: no such file or directory
# which names /proc but is really about the deletion pass that ran before it.
#
# envbuilder already protects /.envbuilder, the workspace folder, the layer cache
# dir and /etc/resolv.conf (envbuilder.go:398-409). This list adds the pieces of
# the chroot that are ours: the /proc and /dev stubs, and the CA bundle the pull
# in stage #1 needs.
#
# SETTING THIS REPLACES THE DEFAULTS rather than extending them
# (options/defaults.go:45), so upstream's three are repeated here.
IGNORE_PATHS="/var/run,/product_uuid,/product_name"
IGNORE_PATHS="${IGNORE_PATHS},/proc,/dev,/kaniko-certs,/etc/hosts,/cache,/out,/ctx"

# envbuilder copies ITSELF into the build context so the built devcontainer can
# re-exec it, reading its own binary from BinaryPath. Staging at the default path
# above means that just works; staging elsewhere without telling it fails late,
# after the local registry has started, with `copy envbuilder binary to build
# context: ... no such file or directory'.
# `env -i' RUNS OUTSIDE THE CHROOT, BEFORE IT. The chroot contains the two Go
# binaries and the stubs and nothing else -- no coreutils, so no /usr/bin/env.
# Written the other way round (`chroot "$KROOT" env -i ...') it fails with
#   chroot: failed to run command 'env': No such file or directory
# which reads as a broken chroot rather than as a missing binary inside one.
# kaniko-build.sh sidesteps this with plain shell prefix assignments; here the
# environment has to be CLEARED as well as set, so env is needed -- from the
# outer filesystem, by absolute path, because `env -i' empties PATH for its own
# lookup of the next command too.
CHROOT_BIN="$(command -v chroot)"

run_envbuilder() {
  env -i \
    USER=root \
    HOME=/tmp \
    PATH=/usr/bin:/bin \
    KANIKO_DIR=/.envbuilder \
    SSL_CERT_FILE=/kaniko-certs/tls-ca-bundle.pem \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    ENVBUILDER_WORKSPACE_FOLDER=/workspace \
    ENVBUILDER_LAYER_CACHE_DIR="$CACHE_IN_ROOT" \
    ENVBUILDER_CACHE_REPO="$CACHE_PLACEHOLDER" \
    ENVBUILDER_IGNORE_PATHS="$IGNORE_PATHS" \
    ENVBUILDER_INIT_SCRIPT="exit 0" \
    ENVBUILDER_INIT_COMMAND=/bin/sh \
    ENVBUILDER_EXIT_ON_BUILD_FAILURE=true \
    ENVBUILDER_EXIT_ON_PUSH_FAILURE=true \
    ENVBUILDER_VERBOSE="${SFD_ENVBUILDER_VERBOSE:-false}" \
    "$@" \
    "$CHROOT_BIN" "$KROOT" /.envbuilder/bin/envbuilder
}

log "building the devcontainer image"
run_envbuilder ENVBUILDER_PUSH_IMAGE=true

# The probe is what reports the digest, in the form
# `ENVBUILDER_CACHED_IMAGE=localhost:<port>/local/cache@sha256:...'. The port is
# ephemeral and differs between the two runs, so only the digest is kept -- the
# publish job re-serves the cache directory on a port of its own choosing.
log "reading back the built image digest"
probe_out="$(run_envbuilder ENVBUILDER_GET_CACHED_IMAGE=true)" \
  || fail "the image was built but the cache probe could not read it back"

# ONLY THE DIGEST COMES FROM THE PROBE LINE. Not the repository -- and the reason
# is a genuine trap.
#
# The line looks like `ENVBUILDER_CACHED_IMAGE=<repo>@sha256:...', so reading the
# repository off it looks obviously right. It is wrong: RunCacheProbe takes its
# options BY VALUE (envbuilder.go:979), so the `opts.CacheRepo = localRegistry'
# override at line 1203 mutates a copy, and cmd/envbuilder/main.go:92 prints the
# CALLER's CacheRepo -- which is still the placeholder this script passed in.
# The digest is correct; the repository name is the placeholder.
probe_line="$(printf '%s\n' "$probe_out" | grep -o 'ENVBUILDER_CACHED_IMAGE=[^[:space:]]*' | head -1)"
[ -n "$probe_line" ] || fail "the cache probe printed no ENVBUILDER_CACHED_IMAGE line"

digest="${probe_line##*@}"
printf '%s' "$digest" | grep -qE '^sha256:[a-f0-9]{64}$' \
  || fail "could not parse a digest out of the cache probe output: $probe_line"

mkdir -p "$OUTDIR"
cp -a "$KROOT/$CACHE_IN_ROOT" "$OUTDIR/layercache"

# THE REPOSITORY IS READ OFF THE STAGED LAYOUT, which is ground truth: it is what
# the publish job will actually serve, and it depends on neither envbuilder's
# internals nor the printing quirk above. A distribution filesystem layout marks
# each repository with a _manifests directory.
REPO_ROOT="$OUTDIR/layercache/docker/registry/v2/repositories"
[ -d "$REPO_ROOT" ] || fail "the staged layer cache has no $REPO_ROOT; envbuilder did not write a registry layout"

mapfile -t repos < <(find "$REPO_ROOT" -type d -name _manifests -printf '%h\n' \
                     | sed "s|^${REPO_ROOT}/||" | sort -u)

# Exactly one, or the publish job has to guess. Guessing here would surface as a
# push of the wrong image, which is worse than refusing.
case "${#repos[@]}" in
  1) repo="${repos[0]}" ;;
  0) fail "the staged layer cache holds no repository" ;;
  *) fail "the staged layer cache holds ${#repos[@]} repositories (${repos[*]}); expected exactly one" ;;
esac

printf '%s\n' "$digest" > "$OUTDIR/image.digest"
printf '%s\n' "$repo" > "$OUTDIR/image.repo"

log "staged devcontainer layer cache at $OUTDIR/layercache ($digest)"
