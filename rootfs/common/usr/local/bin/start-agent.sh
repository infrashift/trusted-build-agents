#!/usr/bin/env bash
# Register one ephemeral Azure Pipelines agent, run exactly one job, deregister.
#
# EPHEMERAL IS THE POINT. kaniko sweeps and rewrites a filesystem, and pipeline
# YAML is supplied by whoever owns the repository being built; neither should be
# able to leave anything behind for the next job, from another repository, to
# find. `run.sh --once' exits after a single job and the container goes with it.
#
# The cost of that design is that deregistration has to be RELIABLE. An agent
# that exits without removing itself stays in the pool as an offline entry, and
# the next container to register with the same name has to --replace it; do that
# often enough and the pool fills with tombstones that make `is anything actually
# listening?' unanswerable at a glance. So removal runs from a trap, on every
# exit path, and its failure is reported but never masks the job's own verdict.
set -euo pipefail

log() { printf '%s start-agent: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

: "${AZP_URL:?AZP_URL is required (e.g. https://dev.azure.com/ryancraig)}"
: "${AZP_TOKEN:?AZP_TOKEN is required}"
: "${AZP_POOL:?AZP_POOL is required}"

# HOME MUST BE SET, AND THE REASON IS NOT OBVIOUS. kaniko resolves $HOME and,
# when it is unset, falls back to looking the current uid up in /etc/passwd --
# which is why the Containerfile appends a UID 1001 entry. Under a jobspec that
# overrides the user to root the lookup is for uid 0, and the error is
# `unable to resolve HOME directory: user: unknown userid 0': an error about HOME
# that is really about NSS, on the first command a pipeline tries.
export HOME="${HOME:-/home/agent}"

AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"
AZP_WORK="${AZP_WORK:-/azp/work}"
mkdir -p "$AZP_WORK"

cd /opt/azdo-agent || fail "the agent distribution is not at /opt/azdo-agent"

# --- deregistration, from a trap, on every exit path ----------------------
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  log "removing agent ${AZP_AGENT_NAME} from pool ${AZP_POOL}"
  # `|| true' on purpose: a failed removal is worth reporting and is never worth
  # turning a passing job into a failing one, or a failing one into a confusing
  # one. The exit code the container reports stays the job's own.
  ./config.sh remove --unattended --auth pat --token "$AZP_TOKEN" >/dev/null 2>&1 \
    || log "WARNING: could not deregister; the pool will hold an offline entry for ${AZP_AGENT_NAME}"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# --replace because a previous container that died without running its trap --
# OOM-killed, node lost -- leaves an offline agent holding this name.
# --acceptTeeEula is required on Linux even though the TEE tooling is unused.
log "registering ${AZP_AGENT_NAME} in pool ${AZP_POOL} at ${AZP_URL}"
./config.sh \
  --unattended \
  --url "$AZP_URL" \
  --auth pat \
  --token "$AZP_TOKEN" \
  --pool "$AZP_POOL" \
  --agent "$AZP_AGENT_NAME" \
  --work "$AZP_WORK" \
  --replace \
  --acceptTeeEula

# NOT `exec'. exec would replace this shell and the EXIT trap with it, so the
# agent would run its one job and vanish without ever deregistering -- the exact
# failure this script is arranged to prevent.
log "running one job, then exiting"
./run.sh --once
