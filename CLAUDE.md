# Working in this repository

Conventions that are load-bearing. Most are inherited from
`trusted-service-containers`, and the ones that differ are marked **DEPARTURE**
with the reason — a convention that differs silently is a convention that will be
"fixed" back by the next person.

## Run this before proposing anything

```bash
make -f Ops.mk validate
```

Schema and cross-references, gitleaks config, single-policy check, Containerfile
lint, image-contract lint, doc path lint, shellcheck, and the policy tests at an
85% coverage floor. It is fast. There is no reason to skip it.

## versions.json is the only place a pin lives

No digest, commit or tarball hash is hardcoded in a Containerfile, a workflow or
a script — `scripts/lint-containerfiles.sh` fails the build if a `sha256:`
literal appears. Every base and toolchain pin is a full digest; every Go tool is
a 40-hex commit, because a tag can be moved and a commit cannot.

A **`track`** is an anchored regex bounding where a pin may legally go.
**Never widen one as part of another change.** It is a policy decision and needs
its own reviewed PR. `^v1\.28\.[0-9]+$`, not `v1\.28\.` — the second also matches
`v11.28.0`. `scripts/validate-schema.py` asserts every pin still lies inside its
own track, which is what catches a version bump that left the policy behind.

## Fail closed, and prove it

`.github/pdp/policies.rego` states a five-point contract at the top. The short
version: `> 0` against a missing value is **undefined** in Rego and therefore
silently non-violating, so every numeric field has an `is_number()` guard *and* a
companion rule that denies when the guard fails. Every enum is read through
`object.get()` with a sentinel against a closed set. When two fields must match,
each side gets a **different** sentinel, so "both absent" compares unequal and
denies. Never write `not <thing_is_bad>` — an undefined helper makes `not` true.

`violations` is a **partial set**, not a complete rule. Two complete rules that
both produce a value for one input conflict at evaluation time, and the conflict
surfaces as an evaluation error rather than a verdict — which a caller reading
only `allow_pipeline` sees as "no answer", not "deny". Partial sets merge.

**When you add a check, break it deliberately and confirm it fails.** Three lint
rules in the sibling repo originally passed by matching their own comments, which
is why every content assertion in `scripts/lint-containerfiles.sh` runs against a
comment-stripped view and never against the raw file.

## The capability boundary is the image, and the pool is how ADO picks it

`image-contract.json` says what each image must and must not contain. It exists
because `microdnf` resolves a dependency **closure**: "the build agent cannot
reach a registry" is true only until something drags skopeo in as a transitive
dependency of something else, and nothing would notice.

In Azure DevOps a job cannot choose its image — it chooses a **pool**. So the
boundary is only real if one pool maps to one image. `validate-schema.py` fails
if two images declare the same pool, and the policy denies an image whose
`io.infrashift.agent.pool` label disagrees with `versions.json`.

`build` holds no credential and carries no registry client. `publish` holds the
Nexus credential and carries no builder. Each names the other in its `forbidden`
list; that symmetry is the point, not decoration.

## DEPARTURE: the runtime base is ubi9-minimal, not ubi9-micro

The sibling service-container repo builds onto `ubi9-micro`. The Azure Pipelines
agent needs a package manager, git and libicu, and micro has none of them.

A consequence worth knowing: ubi9-minimal **already ships `/etc/pki/ca-trust`**,
so there is no `certs` donor stage here. The three stages are `gotools`, `agent`
and `runtime`. The `> 100000` byte assertion on the CA bundle stays anyway — a
truncated bundle ships an image that fails TLS only in production.

## DEPARTURE: one image runs as root, and says so

Every image ships `USER 1001` as its last instruction. `azdo-agent-build` is
*run* as container-root because kaniko must `chroot(2)` into the scratch root it
unpacks the base image over, and chown files to arbitrary uids while assembling
layers. `CAP_SYS_CHROOT` is in the default capability set for container-root; no
`privileged` flag, no added capability, no host mount, no device.

This is recorded as `runtime.runsAsRoot` plus a `runsAsRootReason` in
`versions.json`, and the policy denies the first without a substantive second.
An exemption with no written reason is a drift nobody can review. See
`docs/kaniko-chroot.md`.

## envbuilder is not a drop-in image builder

Read `docs/envbuilder-output.md` before touching
`rootfs/azdo-agent-build/usr/local/bin/envbuilder-build.sh`. Three things there
are counter-intuitive and each one fails late:

- envbuilder unpacks into its own `/` and execs when it finishes, so it runs in
  the same chroot kaniko does, with `ENVBUILDER_INIT_SCRIPT="exit 0"`.
- It has no `--no-push`. Its no-credential property comes from
  `ENVBUILDER_LAYER_CACHE_DIR`, which makes envbuilder serve its own registry on
  loopback and override the cache repo with it.
- `--get-cached-image` is a **dry run** (`RunCacheProbe` sets `NoPush: true`). It
  reads a digest back; it cannot produce an image.

And: **envbuilder does not link the kaniko this repo builds.** Its `go.mod`
replaces kaniko with `github.com/coder/kaniko`. Two different kanikos, forever.

## The staged artifact is never pushed by the thing that built it

`kaniko-build.sh` passes `--no-push` unconditionally and stages an OCI layout.
`envbuilder-build.sh` pushes only to loopback. Neither image contains skopeo. A
job in `Trusted-Publish` picks the artifact up and pushes it.

The destination is **ALLOW_ONCE**: a pushed tag can never be rewritten. So
`push-oci.sh` treats an identical re-push as success — a retried pipeline must
not fail on work that already landed — and a push of *different* content to an
existing name as a hard failure. Getting that pair backwards makes the pipeline
either un-retryable or silently wrong.

## Documentation follows the code

`scripts/lint-docs.sh` fails if a backticked path in `CLAUDE.md`, `README.md`,
`SETUP-ENVIRONMENTS.md`, `.github/pdp/public-keys/README.md` or anything under
`docs/` does not resolve on disk. That list is enumerated, not globbed: a new
document outside `docs/` is unchecked until you add it, and adding it earns a
`selftest-linters.sh` case, or nothing notices when it falls back out.

Write the document after the thing it describes exists. The sibling repo
shipped cards citing four files that were never created, and prose naming a
path nobody can open reads as evidence that the thing exists.
