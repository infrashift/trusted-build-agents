#!/usr/bin/env bash
# Push a staged image to the Nexus OCI registry.
#
# This is the ONLY script in this repository that holds a credential, and it runs
# in the only pool whose image carries a registry client. It cannot author what it
# moves: there is no kaniko, no envbuilder and no compiler in this image, and
# image-contract.json asserts that against the built bytes.
#
# It accepts both staged forms:
#
#   <staged>/image         an OCI layout, from kaniko-build.sh
#   <staged>/layercache    a distribution filesystem layout, from
#                          envbuilder-build.sh, plus image.digest and image.repo
#
# THE DESTINATION IS ALLOW_ONCE. A tag that has been pushed to the Nexus OCI
# repository can never be rewritten. So an identical re-push is a SUCCESS -- a
# retried pipeline must not fail on work that already landed -- and a push of
# DIFFERENT content to a name that exists is a hard failure, never a silent
# no-op. Getting that pair backwards is how a pipeline either cannot be retried
# or quietly reports a push that did not happen.
#
# Usage: push-oci.sh <staged-dir> <destination-ref>
set -euo pipefail

log() { printf '%s push-oci: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

STAGED="${1:?usage: push-oci.sh <staged-dir> <destination-ref>}"
DEST="${2:?missing <destination-ref>, e.g. nexus.example.com/oci/myapp:1.2.3}"

: "${SFD_OCI_CLIENT_ID:?SFD_OCI_CLIENT_ID is required to push an image}"
: "${SFD_OCI_CLIENT_SECRET:?SFD_OCI_CLIENT_SECRET is required to push an image}"

CREDS="${SFD_OCI_CLIENT_ID}:${SFD_OCI_CLIENT_SECRET}"

# PLAIN HTTP IS ALLOWED FOR A LOOPBACK DESTINATION, AND ONLY FOR ONE.
#
# This is deliberately NOT a flag. An `--insecure' switch on the one script that
# holds the registry credential is the kind of thing that gets set once for a
# test and is still set two years later; a rule the destination itself has to
# satisfy cannot be turned on by mistake.
#
# A destination on 127.0.0.1 or localhost is not a registry anyone else can
# reach, and a credential sent there does not leave the machine. Anything else --
# a hostname, a LAN address, Nexus -- gets TLS, with no way to ask otherwise.
# skopeo spells this flag differently per subcommand: `copy' takes
# --src-tls-verify / --dest-tls-verify, `inspect' takes --tls-verify and rejects
# the others outright ("unknown flag: --src-tls-verify"). Two explicit arrays
# rather than one array and a substitution -- the substitution version was wrong
# and read as if it were right.
DEST_COPY_ARGS=()
DEST_INSPECT_ARGS=()
case "${DEST%%/*}" in
  127.0.0.1|127.0.0.1:*|localhost|localhost:*|\[::1\]|\[::1\]:*)
    log "destination is loopback; allowing plain HTTP for this copy only"
    DEST_COPY_ARGS=(--dest-tls-verify=false)
    DEST_INSPECT_ARGS=(--tls-verify=false)
    ;;
esac
REGISTRY_PIDFILE=/azp/serve/registry.pid
export REGISTRY_PIDFILE

cleanup() {
  if [ -f "$REGISTRY_PIDFILE" ]; then
    kill "$(cat "$REGISTRY_PIDFILE")" 2>/dev/null || true
    rm -f "$REGISTRY_PIDFILE"
  fi
}
trap cleanup EXIT INT TERM

# --- work out what was staged, and build a skopeo source ref --------------
if [ -d "$STAGED/image" ]; then
  # kaniko: an OCI layout holding exactly one manifest, so `oci:<dir>' resolves
  # it with no tag.
  SRC="oci:${STAGED}/image"
  SRC_COPY_ARGS=()
  SRC_INSPECT_ARGS=()
elif [ -d "$STAGED/layercache" ]; then
  digest="$(cat "$STAGED/image.digest")"
  repo="$(cat "$STAGED/image.repo")"
  addr="$(serve-layer-cache.sh "$STAGED/layercache")"
  SRC="docker://${addr}/${repo}@${digest}"
  # The loopback registry is plain HTTP and holds nothing secret; it is reachable
  # only from this container and only for the length of this copy.
  SRC_COPY_ARGS=(--src-tls-verify=false)
  SRC_INSPECT_ARGS=(--tls-verify=false)
else
  fail "$STAGED holds neither an OCI layout at image/ nor a layer cache at layercache/"
fi

# --- what is already at the destination? ----------------------------------
local_digest="$(skopeo inspect "${SRC_INSPECT_ARGS[@]}" --format '{{.Digest}}' "$SRC")" \
  || fail "could not read the staged image at $SRC"
log "staged digest $local_digest"

# DISTINGUISH "not there" FROM "cannot look". Both make skopeo exit non-zero, and
# treating an auth failure as "the tag is free" turns a credential problem into a
# push that fails later with a less useful message.
inspect_err="$(mktemp)"
if remote_digest="$(skopeo inspect "${DEST_INSPECT_ARGS[@]}" --creds "$CREDS" --format '{{.Digest}}' "docker://${DEST}" 2>"$inspect_err")"; then
  if [ "$remote_digest" = "$local_digest" ]; then
    log "$DEST already holds $local_digest -- nothing to do"
    exit 0
  fi
  fail "$DEST EXISTS WITH DIFFERENT CONTENT (remote $remote_digest, staged $local_digest).
       The OCI repository is ALLOW_ONCE: this tag cannot be rewritten and the
       release has to be re-cut under a new one."
elif ! grep -qiE 'manifest unknown|not found|name unknown|404' "$inspect_err"; then
  fail "could not determine whether $DEST already exists. This is not the same as
       the tag being free, so the push is not attempted: $(tr '\n' ' ' < "$inspect_err")"
fi

log "pushing $local_digest to $DEST"
skopeo copy "${SRC_COPY_ARGS[@]}" "${DEST_COPY_ARGS[@]}" \
  --dest-creds "$CREDS" \
  --preserve-digests \
  "$SRC" "docker://${DEST}"

# Verify rather than trust the exit code: --preserve-digests is what makes this
# assertion meaningful, and a registry that rewrote the manifest would otherwise
# be discovered by whoever pulled it next.
pushed="$(skopeo inspect "${DEST_INSPECT_ARGS[@]}" --creds "$CREDS" --format '{{.Digest}}' "docker://${DEST}")"
[ "$pushed" = "$local_digest" ] \
  || fail "pushed digest $pushed does not match the staged digest $local_digest"

log "pushed $DEST@$pushed"
