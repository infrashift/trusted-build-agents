# Getting an image out of envbuilder

This document exists because the obvious reading of envbuilder's documentation
leads to three wrong designs in a row, and each one fails late.

Everything below was established by reading `envbuilder` at the pinned commit in
`versions.json` (`coder/envbuilder` v1.3.0), not from its README.

## What envbuilder actually is

envbuilder turns a repository containing a `devcontainer.json` into a **running
development environment**. It embeds kaniko as a library, builds the image *in
place*, and then **execs into it**. It is designed to be a container's PID 1.

Three consequences follow, and all three matter here.

### 1. It unpacks the base image into its own `/`

Exactly as kaniko does, because it *is* kaniko. Run directly on the agent, it
would sweep the agent's own root filesystem out from under the Azure Pipelines
job that invoked it — and that job still has to survive long enough to report
the result.

So `envbuilder-build.sh` runs it inside the **same chroot** kaniko uses, prepared
by `rootfs/azdo-agent-build/usr/local/bin/kaniko-chroot.sh`. Same three stubs,
same reasons. See `docs/kaniko-chroot.md`.

### 2. It has no `--no-push`

`kaniko-build.sh` gets its no-credential property from a flag. envbuilder has no
equivalent: producing a distributable image **requires** `ENVBUILDER_PUSH_IMAGE=true`
and a cache repo, and `Run()` refuses without one:

```go
if opts.CacheRepo == "" && opts.PushImage {
    return fmt.Errorf("--cache-repo must be set when using --push-image")
}
```

The way out is `ENVBUILDER_LAYER_CACHE_DIR`. When it is set, envbuilder starts an
**in-process registry** over that directory and *overrides* the cache repo with
it:

```go
if opts.LayerCacheDir != "" {
    if opts.CacheRepo != "" {
        opts.Logger(log.LevelWarn, "Overriding cache repo with local registry...")
    }
    localRegistry, closeLocalRegistry, err := serveLocalRegistry(ctx, opts.Logger, opts.LayerCacheDir)
    ...
    opts.CacheRepo = localRegistry
}
```

`serveLocalRegistry` binds `127.0.0.1:0` and returns `localhost:<port>/local/cache`.
So the push goes to loopback, on an ephemeral port, and **needs no credential**.
That is how the build pool keeps the property the whole split exists for.

`ENVBUILDER_CACHE_REPO` is therefore never set by our scripts, and
`image-contract.json` asserts that it is not: naming a remote there would
reintroduce exactly the credential this design removes.

### 3. It execs when it finishes

`Run()` does not return after pushing; it execs the devcontainer's init command.
`ENVBUILDER_INIT_SCRIPT="exit 0"` makes that exec a no-op so control returns to
the pipeline.

## Why `--get-cached-image` cannot produce the image

This is the wrong turn worth naming, because the flag sounds like it would.

`ENVBUILDER_GET_CACHED_IMAGE=true` runs `RunCacheProbe`, whose own doc comment
says it "performs a 'dry-run' build of the image and checks that all of the
resulting layers are present in options.CacheRepo". Its kaniko options set
`NoPush: true` unconditionally. It **reads back**; it does not produce.

So the build takes two invocations, and that is not redundancy:

1. `ENVBUILDER_PUSH_IMAGE=true` — builds and pushes to the loopback registry.
2. `ENVBUILDER_GET_CACHED_IMAGE=true` — reports
   `ENVBUILDER_CACHED_IMAGE=localhost:<port>/local/cache@sha256:...`, which is
   where the digest comes from.

The port differs between the two runs because it is ephemeral, so only the
**digest** is kept. The repository name is always `local/cache`.

## Why the publish job needs a registry binary

envbuilder does not write an OCI layout. It writes through the `distribution`
filesystem storage driver, producing `docker/registry/v2/...` on disk.

skopeo has no transport that reads that: `oci:` wants an OCI layout, `dir:` wants
skopeo's own format. The only thing that reads a distribution filesystem layout
is distribution itself.

So `azdo-agent-publish` carries the `registry` binary, built from the pinned
commit in `versions.json`, and `serve-layer-cache.sh` runs it on `127.0.0.1` for
the length of one `skopeo copy`. It is bound to loopback, started with no
credential, and stopped by the trap in `push-oci.sh`.

The alternative — walking the layout by hand to assemble an OCI layout — means
depending on registry internals that are explicitly not a public interface. One
pinned binary is the cheaper and more honest option.

## Six things that only showed up when it was run

Every one of these fails *late* — after the local registry has started, or after
the image has already been pushed — so none of them is visible from reading the
options list.

**1. `env -i` runs outside the chroot, before it.** The chroot holds two Go
binaries and the stubs; there is no `/usr/bin/env` in it. Written the intuitive
way round (`chroot "$KROOT" env -i ...`) it fails with `chroot: failed to run
command 'env': No such file or directory`, which reads as a broken chroot rather
than a missing binary inside one. `env -i` also empties `PATH` for its own lookup
of the next command, so `chroot` needs an absolute path.

**2. `SSL_CERT_FILE` has to be passed explicitly.** `env -i` clears it, and
envbuilder pulls the base image over TLS.

**3. `ENVBUILDER_CACHE_REPO` must be set, and is then ignored.** This is the one
that invalidated the original design. The guard

```go
// envbuilder.go:141
if opts.CacheRepo == "" && opts.PushImage {
    return fmt.Errorf("--cache-repo must be set when using --push-image")
}
```

runs **before** the override at line 386 that would have made it unnecessary. So
`ENVBUILDER_LAYER_CACHE_DIR` alone dies at the guard. The value is a placeholder
that exists only to get past line 141, and it is `localhost:1/...` so that it
**fails closed**: if the override ever stops happening, the push is refused by a
port that accepts nothing, rather than reaching a real registry.

**4. `ENVBUILDER_BINARY_PATH`.** envbuilder copies *itself* into the build context
so the built devcontainer can re-exec it, and looks for its binary at
`options/defaults.go:69`'s `/.envbuilder/bin/envbuilder`. Rather than override
the path, `envbuilder-build.sh` stages it there — envbuilder's own layout, which
also satisfies the next item.

**5. `KANIKO_DIR` must equal `/.envbuilder`.** envbuilder has a safety check of
its own before it lets the embedded kaniko delete anything:

```
KANIKO_DIR is not set to /.envbuilder. Bailing!
To bypass this check, set FORCE_SAFE=true.
```

That check exists to stop envbuilder wiping a real system. It is **satisfied**
here, never bypassed — `FORCE_SAFE` would disable exactly the protection that
matters, on the one code path that deletes things. `image-contract.json` forbids
the string.

**6. `ENVBUILDER_IGNORE_PATHS` must protect the chroot stubs.** envbuilder deletes
the filesystem as its own stage #0, *before* the embedded kaniko initialises — so
`--ignore-path` cannot save anything kaniko needs afterwards. Losing the `/proc`
stub this way gives

```
do build: failed to initialize ignore list: checking filesystem mount paths
for ignore list: open /proc/self/mountinfo: no such file or directory
```

which names `/proc` but is really about a deletion pass that ran earlier.
envbuilder already protects `/.envbuilder`, the workspace folder, the layer cache
dir and `/etc/resolv.conf` (`envbuilder.go:398-409`); the script adds `/proc`,
`/dev`, `/kaniko-certs` and `/etc/hosts`. Setting the variable **replaces**
upstream's defaults rather than extending them (`options/defaults.go:45`), so
those three are repeated.

## A devcontainer whose image has no resolvable user will fail after the push

envbuilder builds, pushes, and *then* resolves the user to exec into the
environment. An image whose `USER` has no `/etc/passwd` entry — which is exactly
the shape of a hardened UBI base — fails there with

```
error: update user: find user: user: unknown userid 1001
```

**after the image has already been pushed to the local registry.** The build
genuinely succeeded; only the step that exists for envbuilder's real purpose
(running the environment) failed.

Real devcontainers define a user, so the normal path is fine. But it is worth
knowing that the exit code of the build invocation is not, on its own, the
question you are asking — which is why the digest is read back with a separate
probe rather than trusted from the first run.

## The devcontainer path does not reproduce, and the reason is precise

Two builds of the identical workspace produce different image digests. The kaniko
path, by contrast, reproduced byte-identically across two independent runs.

It is not non-determinism in the build. Measured on two runs of the same
devcontainer: the differing layers hold the **same files, same modes, same
owners, same sizes, and the same concatenated content hash**, and `tar -tv` shows
every mtime already zeroed to `1969-12-31`. The tars still differ, at byte 529:

```
30 atime=1788279348.245610115      30 atime=1788279447.112282669
30 ctime=1788279344.830749676      30 ctime=1788279446.043275406
```

**PAX extended headers.** kaniko's `Reproducible` zeroes `mtime` but leaves
`atime` and `ctime` carrying live wall-clock values, and envbuilder builds with
`SnapshotMode: "redo"` and zstd compression rather than the executor's defaults.

This is **not gated**, and should not be. It matches the position the forge
already took: whether something reproduces is a property of its ecosystem, and
failing a build for it would block the ecosystems that cannot yet control it. The
fact is recorded so it accumulates as data rather than as opinion.

What it does mean in practice: **do not use the devcontainer digest as a cache
key across pipeline runs**, and do not expect a rebuild of an unchanged
devcontainer to be a no-op at the registry. `push-oci.sh` will treat it as a
DIFFERENT image and refuse the tag, which is the correct behaviour for an
ALLOW_ONCE destination — tag devcontainer images with the build id, not with a
content-derived name.

## Read the repository off the staged layout, never off the probe line

The probe prints `ENVBUILDER_CACHED_IMAGE=<repo>@<digest>`, so taking the
repository from it looks obviously right. It is wrong, and quietly so.

`RunCacheProbe` takes its options **by value** (`envbuilder.go:979`). The
`opts.CacheRepo = localRegistry` override at line 1203 therefore mutates a copy,
and `cmd/envbuilder/main.go:92` prints the *caller's* `CacheRepo` — which is
still the placeholder this script passed in to satisfy the line-141 guard. The
digest on that line is correct; the repository is not.

So `envbuilder-build.sh` takes only the digest from the probe, and derives the
repository from the staged layout itself by looking for `_manifests`
directories — ground truth, and what the publish job will actually serve. It
asserts exactly one repository rather than guessing, because guessing surfaces as
a push of the wrong image.

## The asymmetry, stated plainly

| | kaniko path | envbuilder path |
|---|---|---|
| no-credential property comes from | `--no-push`, a literal flag | the push target being loopback |
| staged artifact | OCI layout (`image/`) | distribution layout (`layercache/`) |
| publish reads it with | `skopeo copy oci:...` | `registry serve` + `skopeo copy docker://127.0.0.1:...` |

Both end at the same place: a digest that `push-oci.sh` compares against the
destination before and after the copy.

## One more thing that is true and easy to miss

**envbuilder does not link the kaniko this repository builds.** Its `go.mod`
carries:

```
replace github.com/GoogleContainerTools/kaniko => github.com/coder/kaniko v0.0.0-20251107135632-b20ff58093d8
```

The standalone `kaniko-executor` comes from `osscontainertools/kaniko` at the
commit in `versions.json`; envbuilder's embedded builder comes from Coder's fork.
They are two different kanikos and always will be. Do not assume a flag, a cache
format or a bug fix present in one is present in the other.
