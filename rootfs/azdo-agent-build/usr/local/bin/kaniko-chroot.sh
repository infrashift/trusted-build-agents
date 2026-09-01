#!/usr/bin/env bash
# Build the scratch root kaniko runs in, and stub the three files it reads.
#
# WHY A CHROOT AT ALL. kaniko unpacks the base image into its own `/', after
# deleting everything outside its ignore list. So kaniko and the agent CANNOT
# share a root filesystem: the agent's /bin, /usr/bin and /etc/passwd are exactly
# the paths a base image populates, and the Azure Pipelines agent has to still be
# running after `make image' finishes in order to report the result. Sparing
# those paths from the sweep would stop the base image writing them; not sparing
# them would destroy the agent mid-job.
#
# This costs NO new privilege. CAP_SYS_CHROOT is in the default capability set
# for container-root and is the same capability BUILDAH_ISOLATION=chroot relied
# on before kaniko replaced it. No privileged flag, no added capability, no host
# mount, no device.
#
# Ported from golden/scripts/image.sh in the sshadowforge forge. Every line below
# was paid for there; see docs/kaniko-chroot.md before changing one.
set -euo pipefail

log() { printf '%s kaniko-chroot: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

KROOT="${SFD_KANIKO_ROOT:-/azp/kaniko}"

command -v kaniko-executor >/dev/null 2>&1 \
  || fail "kaniko-executor is not on PATH. This script runs in the Trusted-Build pool, which is the only pool whose image carries kaniko; reaching here means the job asked for the wrong pool."

# A stale root from an interrupted job would be unpacked over and its leftovers
# would end up in the next image. Rebuild it, every time.
rm -rf "$KROOT"
mkdir -p "$KROOT"/{ctx,out,cache,layercache,workspace,dev,tmp,etc,kaniko} "$KROOT/proc/self"

# kaniko resolves $HOME and falls back to an /etc/passwd lookup when it is unset.
# Inside the chroot the agent's own /etc/passwd is not reachable, so give it one.
printf 'root:x:0:0:root:/tmp:/bin/sh\n' > "$KROOT/etc/passwd"
printf 'root:x:0:\n'                    > "$KROOT/etc/group"

# THE THREE STUBS. Each is load-bearing and each names a real error message.
#
#   proc/self/mountinfo  kaniko reads it to seed its ignore list; absent, it dies
#                        with `failed to initialize ignore list'. EMPTY IS
#                        CORRECT -- there are no mounts to discover here, and the
#                        paths that must be spared are passed as --ignore-path.
#                        Mounting a real procfs would need CAP_SYS_ADMIN, the one
#                        privilege this design exists to avoid.
#
#   proc/self/exe        kaniko locates its own binary through it, and derives
#                        its WORKING DIRECTORY from the result. Absent, the error
#                        is `couldn't determine location of kaniko exe'.
#
#                        IT MUST POINT INTO A SUBDIRECTORY, NOT AT THE CHROOT
#                        ROOT. kaniko adds the directory containing its own
#                        binary to the ignore list, so an executor staged at
#                        /kaniko-executor makes that directory `/' -- and kaniko
#                        then ignores the ENTIRE FILESYSTEM. The build still
#                        succeeds, still reports a digest, and every layer comes
#                        out EMPTY: `Adding to layer: []' with `Ignore list:
#                        [{/ false} ...]'. Staging at /kaniko/executor makes the
#                        ignored directory /kaniko, which is what upstream
#                        expects. See docs/kaniko-chroot.md.
#
#   dev/null             a PLAIN FILE, not a device node: CAP_MKNOD is not in the
#                        default capability set, so mknod would fail here.
: > "$KROOT/proc/self/mountinfo"
: > "$KROOT/dev/null"
cp "$(command -v kaniko-executor)" "$KROOT/kaniko/executor" \
  || fail "could not stage kaniko-executor into $KROOT/kaniko"
ln -sf /kaniko/executor "$KROOT/proc/self/exe"

# RESOLVER AND TRUST, and this is the part a reading of the forge's script does
# not give you. There, every FROM resolves from a pre-warmed local cache and the
# build machine has no network at all -- so kaniko never does DNS and never does
# TLS. An Azure DevOps agent builds arbitrary repositories naming arbitrary base
# images; it has to be able to PULL.
#
# Without /etc/resolv.conf inside the chroot, Go's pure resolver falls back to
# localhost and the failure is
#   dial tcp: lookup ghcr.io on [::1]:53: read: connection refused
# which reads as a network outage rather than as a missing file.
for f in /etc/resolv.conf /etc/hosts; do
  [ -r "$f" ] && cp -L "$f" "$KROOT$f"
done

# The CA bundle lives OUTSIDE /etc on purpose. kaniko deletes everything not in
# its ignore list before unpacking the base image, and a bundle under /etc would
# either be swept -- breaking TLS for a second FROM -- or have to be spared by an
# --ignore-path that then also spares the base image's own /etc/pki.
mkdir -p "$KROOT/kaniko-certs"
cp -L "${SSL_CERT_FILE:-/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem}" \
   "$KROOT/kaniko-certs/tls-ca-bundle.pem" \
  || fail "could not stage the CA bundle into $KROOT"

log "chroot prepared at $KROOT"
