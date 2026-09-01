#!/usr/bin/env bash
# Structural lint for the agent Containerfiles.
#
# Near-identical files drift. The two here already differ in ways that are
# intended (one carries kaniko, the other skopeo) and would differ in ways that
# are not if nothing checked. These assertions make the shape mechanical and
# cross-check every runtime declaration against versions.json, so the two cannot
# disagree.
#
# Adapted from scripts/lint-containerfiles.sh in trusted-service-containers. The
# shape differs -- three stages here are gotools/agent/runtime, not
# builder/certs/runtime, because ubi9-minimal ships its own CA bundle and needs
# no donor -- but the reasons are the same and are restated at each check.
set -euo pipefail

python3 - <<'PY'
import json, os, re, sys

V = json.load(open('versions.json'))
fail = []
def err(f, m): fail.append(f"{f}: {m}")

REQUIRED_LABELS = [
    "org.opencontainers.image.source",
    "org.opencontainers.image.revision",
    "org.opencontainers.image.version",
    "io.infrashift.image.upstream.digest",
    "io.infrashift.image.upstream.source",
]

images = V['images']
sources = V['sources']

declared = {img['containerfile'] for img in images.values()}
on_disk = {os.path.join('Containerfiles', f) for f in os.listdir('Containerfiles')
           if f.endswith('.Containerfile')}
# validate-schema.py owns declared<->on_disk; repeating it here would report the
# same problem twice with two different wordings.

def instructions(text):
    """Logical Containerfile instructions, with continuations joined."""
    out, buf = [], ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        buf += line
        if line.endswith('\\'):
            buf = buf[:-1] + " "
            continue
        out.append(buf.strip())
        buf = ""
    if buf.strip():
        out.append(buf.strip())
    return out

for name, img in sorted(images.items()):
    p = img['containerfile']
    if p not in on_disk:
        continue
    ins = instructions(open(p).read())
    # Comment-stripped view. EVERY content assertion below runs against this and
    # never against the raw text: the comments in these files deliberately name
    # the flags and paths being asserted, so scanning raw text would let a check
    # pass on its own documentation. Three lint rules in the sibling repo
    # originally did exactly that.
    code = "\n".join(ins)
    heads = [i.split(None, 1)[0].upper() for i in ins]
    rt = img['runtime']

    # --- Pre-FROM global ARGs -------------------------------------------
    first_from = next((n for n, h in enumerate(heads) if h == 'FROM'), None)
    if first_from is None:
        err(p, "no FROM instruction"); continue
    pre_names = {i.split()[1] for i in ins[:first_from] if i.upper().startswith('ARG ')}
    for need in ("UPSTREAM_BASE", "UPSTREAM_DIGEST", "TOOLCHAIN_BASE", "TOOLCHAIN_DIGEST"):
        if need not in pre_names:
            err(p, f"missing pre-FROM `ARG {need}`")

    # --- ARGs re-declared after the LAST FROM ---------------------------
    # ARGs before the first FROM are global build args and are NOT in scope
    # inside a stage, so the LABELs would expand to empty strings. This is the
    # real bug both sibling repos had to fix.
    last_from = max(n for n, h in enumerate(heads) if h == 'FROM')
    post = {i.split()[1] for i in ins[last_from:] if i.upper().startswith('ARG ')}
    for need in ("UPSTREAM_BASE", "UPSTREAM_DIGEST"):
        if need not in post:
            err(p, f"`ARG {need}` is not re-declared after the runtime FROM; "
                   f"the LABEL referencing it would expand to an empty string")

    # --- Exactly three stages, digest-pinned ----------------------------
    froms = [i for i in ins if i.upper().startswith('FROM ')]
    if len(froms) != 3:
        err(p, f"expected 3 stages (gotools, agent, runtime), found {len(froms)}")
    for f in froms:
        if '@${' not in f:
            err(p, f"FROM is not digest-pinned via a build arg: {f!r}")
    for stage in ('GOTOOLS', 'AGENT'):
        if not any(f.upper().endswith(f' AS {stage}') for f in froms):
            err(p, f"no `AS {stage.lower()}` stage")

    # --- No hardcoded digests: versions.json is the only pin ------------
    for m in re.finditer(r'sha256:[a-f0-9]{7,}', code):
        err(p, f"hardcoded digest {m.group(0)[:20]}...; digests belong in versions.json only")

    # --- Exactly one LABEL block, carrying all five required labels -----
    labels = [i for i in ins if i.upper().startswith('LABEL ')]
    if len(labels) != 1:
        err(p, f"expected exactly 1 LABEL instruction, found {len(labels)}")
    else:
        for need in REQUIRED_LABELS:
            if need + '=' not in labels[0]:
                err(p, f"LABEL block is missing the policy-required `{need}`")
        if f'io.infrashift.agent.pool="{img["pool"]}"' not in labels[0]:
            err(p, f"LABEL does not carry io.infrashift.agent.pool=\"{img['pool']}\" "
                   f"to match versions.json; the pool IS the capability boundary and an "
                   f"image that does not say which one it belongs to cannot be audited")

    # --- The vendor tarball is verified BEFORE it is unpacked -----------
    # An archive that fails its hash must never have been unpacked: the failure
    # mode of unpacking first is a tree that looks right and came from elsewhere.
    if 'sha256sum -c' not in code:
        err(p, "does not verify the agent tarball with `sha256sum -c`")
    else:
        checked = code.index('sha256sum -c')
        untarred = code.find('tar -C /out/agent')
        if untarred != -1 and untarred < checked:
            err(p, "unpacks the agent tarball BEFORE verifying its sha256")

    # --- Every Go tool is pinned to a commit, and the pin is asserted ---
    if 'CGO_ENABLED=0' not in code:
        err(p, "does not set CGO_ENABLED=0; a dynamically linked binary from the "
               "Debian toolchain cannot run on ubi9's glibc")
    for tool in img['goTools']:
        argname = tool.upper() + '_COMMIT'
        if f'ARG {argname}' not in code:
            err(p, f"goTools names {tool!r} but the Containerfile declares no `ARG {argname}`")
        if f'rev-parse HEAD)" = "${{{argname}}}"' not in code:
            err(p, f"does not assert the fetched {tool} tree is exactly ${{{argname}}}; "
                   f"a shallow fetch of a MOVED tag would otherwise succeed quietly")

    # --- CA bundle is present and non-trivial ---------------------------
    # ubi9-minimal ships its own, unlike ubi9-micro, so there is no donor stage --
    # but a truncated bundle would still ship an image that fails TLS only in
    # production, so the size assertion stays.
    if '-gt 100000' not in code:
        err(p, "does not assert the CA bundle is non-trivial")

    # --- Non-root by default, group 0, USER 1001 LAST -------------------
    # runsAsRoot is about how the image is RUN, not what it declares. An image
    # that shipped USER 0 would be root everywhere, including in the pools that
    # have no reason to be.
    if 'x:1001:0:' not in code:
        err(p, "does not append a UID 1001 / GID 0 passwd entry")
    if 'chmod -R g=u' not in code:
        err(p, "does not `chmod g=u`; the image would break under OpenShift's arbitrary-UID SCC")
    if not ins or ins[-1].upper() != 'USER 1001':
        err(p, f"last instruction must be `USER 1001`, found {ins[-1]!r}" if ins else "empty file")

    # --- Runtime declarations agree with versions.json ------------------
    ep = next((i for i in ins if i.upper().startswith('ENTRYPOINT ')), None)
    if ep is None:
        err(p, "no ENTRYPOINT")
    else:
        try:
            got = json.loads(ep[len('ENTRYPOINT '):])
        except Exception:
            err(p, "ENTRYPOINT must be exec form (a JSON array); shell form loses PID-1 signal handling")
            got = None
        if got is not None and got != rt['entrypoint']:
            err(p, f"ENTRYPOINT {got} disagrees with versions.json runtime.entrypoint {rt['entrypoint']}")

    # An agent image must not EXPOSE anything. The Azure Pipelines agent is
    # outbound long-poll only; a listening port would be a claim about this image
    # that is not true.
    if any(h == 'EXPOSE' for h in heads):
        err(p, "declares EXPOSE; the agent makes only outbound connections and listens on nothing")

if fail:
    for m in fail:
        print(f"error: {m}", file=sys.stderr)
    print(f"\n{len(fail)} Containerfile issue(s)", file=sys.stderr)
    sys.exit(1)

print(f"OK: {len(images)} Containerfiles pass shape and versions.json agreement")
PY
