#!/usr/bin/env bash
# Serve a directory envbuilder wrote as a read-only registry on loopback.
#
# WHY THIS EXISTS. envbuilder does not emit an OCI layout. It writes through the
# `distribution' filesystem storage driver, into the layout
# `docker/registry/v2/...' -- and skopeo has no transport that reads that from
# disk. `oci:' wants an OCI layout and `dir:' wants skopeo's own format; neither
# is what is on disk. The only thing that reads a distribution filesystem layout
# is distribution itself.
#
# So we run one, on 127.0.0.1, for the length of one copy, and stop it. It is
# bound to loopback and started with no credential: nothing outside this
# container can reach it, and it is gone before the step ends.
#
# The alternative -- reimplementing the layout walk to assemble an OCI layout by
# hand -- means parsing registry internals that are explicitly not a public
# interface. This costs one binary and no assumptions.
#
# Usage: serve-layer-cache.sh <layer-cache-dir>
#        Prints the address it is listening on. The caller must stop it.
set -euo pipefail

log() { printf '%s serve-layer-cache: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

CACHE_DIR="${1:?usage: serve-layer-cache.sh <layer-cache-dir>}"
[ -d "$CACHE_DIR/docker/registry/v2" ] \
  || fail "$CACHE_DIR does not look like a distribution filesystem layout (no docker/registry/v2). Was it produced by envbuilder-build.sh?"

PORT="${REGISTRY_PORT:-5000}"
CONFIG="$(mktemp -t registry-XXXXXX.yml)"
PIDFILE="${REGISTRY_PIDFILE:-/azp/serve/registry.pid}"
mkdir -p "$(dirname "$PIDFILE")"

cat > "$CONFIG" <<YAML
version: 0.1
log:
  level: error
storage:
  filesystem:
    rootdirectory: ${CACHE_DIR}
  maintenance:
    uploadpurging:
      enabled: false
http:
  addr: 127.0.0.1:${PORT}
YAML

# STDOUT AND STDERR MUST BE REDIRECTED, and not for tidiness. push-oci.sh calls
# this script inside a command substitution to capture the address. A background
# process that inherits the substitution's stdout keeps that pipe open, so the
# substitution BLOCKS FOREVER waiting for a registry that is running perfectly
# well. The symptom is a publish step that hangs with no output at all.
REGISTRY_LOG="${REGISTRY_LOG:-/azp/serve/registry.log}"
registry serve "$CONFIG" >"$REGISTRY_LOG" 2>&1 &
echo $! > "$PIDFILE"

# Poll rather than sleep. A fixed sleep is either too short on a loaded node --
# where the failure is a confusing connection-refused from skopeo -- or wasted
# time on every run.
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${PORT}/v2/" >/dev/null 2>&1; then
    log "serving $CACHE_DIR at 127.0.0.1:${PORT} (pid $(cat "$PIDFILE"))"
    printf '127.0.0.1:%s\n' "$PORT"
    exit 0
  fi
  sleep 0.2
done

# The registry's own last words. Without them the only symptom is a timeout,
# which says nothing about whether the port was taken or the layout unreadable.
log "last lines from the registry:"
tail -5 "$REGISTRY_LOG" >&2 2>/dev/null || true
fail "the registry did not become ready on 127.0.0.1:${PORT}"
