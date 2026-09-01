# Why kaniko runs in a chroot

Ported, with its reasoning, from `runner/CONTAINER-CONTRACT.md` in the
sshadowforge forge (`ansible-collection-infrashift-hashistack`). Every line of
`rootfs/azdo-agent-build/usr/local/bin/kaniko-chroot.sh` was paid for there.

## The problem

**kaniko unpacks the base image into its own `/`**, after deleting everything
outside its ignore list.

On an Azure Pipelines agent that is fatal in a specific way: the agent process
must still be running after the build finishes, because it is what reports the
result and then deregisters itself. Its `/bin`, `/usr/bin` and `/etc/passwd` are
exactly the paths a base image populates. Sparing them from the sweep would stop
the base image writing them; not sparing them destroys the agent mid-job.

kaniko and the agent therefore **cannot share a root filesystem**.

Giving kaniko its own pipeline job does not help either — the artifact has to
come back to the job that publishes it, and an ADO job's steps all run in the
same container.

## The solution, and what it costs

A scratch root under `/azp/kaniko`, and `chroot(2)` into it.

That costs **no new privilege**. `CAP_SYS_CHROOT` is in the default capability
set for container-root and is the same capability `BUILDAH_ISOLATION=chroot`
relied on before kaniko replaced it. The `Trusted-Build` pool runs its container
as root with the default set: no `privileged` flag, no added capability, no host
mount, no device.

This is the one exemption in this repository, and `versions.json` records it as
`runtime.runsAsRoot` with a `runsAsRootReason`. The policy denies an image that
claims the first without the second.

## The three stubs

Each is load-bearing and each names a real error message. They are what a naive
`mkdir` misses.

| stub | why |
|---|---|
| `proc/self/mountinfo`, empty | kaniko reads it to seed its ignore list; absent, it dies with `failed to initialize ignore list`. **Empty is correct** — there are no mounts to discover, and the paths that must be spared are passed as `--ignore-path`. |
| `proc/self/exe` → `/kaniko/executor` | kaniko locates its own binary through it; absent, `couldn't determine location of kaniko exe`. **It must point into a subdirectory** — see below. |
| `dev/null`, a **plain file** | `CAP_MKNOD` is not in the default capability set, so a device node cannot be created here. A plain file is enough for everything kaniko writes to it. |

Mounting a real `procfs` would need `CAP_SYS_ADMIN`, which is the one privilege
this design exists to avoid. For the same reason the build context is **copied**
into the chroot rather than bind-mounted.

## The executor must not live at the chroot root

This one cost the most to find, and it is worth stating plainly because the
symptom looks like success.

kaniko resolves `/proc/self/exe` and adds **the directory containing its own
binary** to its ignore list. That is normally `/kaniko`, which is why upstream
images put it there. Stage the executor at `/kaniko-executor` — at the chroot
root — and the directory kaniko decides to ignore is `/`:

```
DEBU Ignore list: [{/ false} {/etc/mtab false} {/tmp/apt-key-gpghome true} ...]
DEBU Adding to layer: []
```

Every layer comes out empty. The build **succeeds**, prints
`Skipping push to container registry due to --no-push flag`, writes a valid OCI
layout and reports a digest that skopeo agrees with. The image is well-formed
and contains nothing. A `RUN` that writes a file logs the file being written,
the file is on disk in the chroot afterwards, and it is in no layer.

Staging at `/kaniko/executor` gives the expected list and the expected result:

```
DEBU Ignore list: [{/kaniko false} {/etc/mtab false} ...]
DEBU Adding to layer: [/ /hello.txt]
```

`image-contract.json` asserts the staging path, and
`scripts/selftest-linters.sh` mutates it back and fails if the assertion does
not object. Nothing else in this repository would catch it: there is no
malformed artifact to detect.

envbuilder embeds kaniko and inherits the behaviour exactly, so it is staged at
`/kaniko/envbuilder` for the same reason.

## Two things the forge's script does not need, and this one does

Both were found by running it, not by reading it. The forge builds **offline**,
resolving every `FROM` from a pre-warmed local cache on a machine with no
registry client and no network. An Azure DevOps agent builds arbitrary
repositories naming arbitrary base images, so it has to **pull** — and pulling
needs two things the chroot did not have.

### `--force` is required, and it is not a loosening

kaniko refuses to start unless it believes it is in a container:

```go
if !checkContained() {
    if !force {
        exit(errors.New("kaniko should only be run inside of a container, run with the --force flag ..."))
    }
```

`checkContained()` is `proc.GetContainerRuntime(...)`, which reads
`/proc/self/cgroup` and `/proc/self/mountinfo`. Inside the chroot those are the
stubs above — and the **empty `mountinfo` is required for the ignore list**. The
detection cannot be satisfied without breaking the thing it would be satisfied
for.

We *are* in a container. kaniko simply cannot see it from in there. `--force`
says so; it grants nothing.

### DNS and CA trust have to be staged in

Without `/etc/resolv.conf` inside the chroot, Go's pure resolver falls back to
localhost:

```
error building image: ... Get "https://ghcr.io/v2/": dial tcp:
  lookup ghcr.io on [::1]:53: read udp [::1]:37046->[::1]:53: connection refused
```

which reads as a network outage rather than as a missing file. `kaniko-chroot.sh`
copies `/etc/resolv.conf` and `/etc/hosts` in.

The CA bundle is staged at **`/kaniko-certs/tls-ca-bundle.pem`, outside `/etc` on
purpose**, with `SSL_CERT_FILE` pointing at it. kaniko deletes everything not in
its ignore list before unpacking the base image, so a bundle under `/etc` would
either be swept — breaking TLS for a second `FROM` — or need an `--ignore-path`
that also spares the base image's own `/etc/pki`. `/kaniko-certs`,
`/etc/resolv.conf` and `/etc/hosts` are passed as `--ignore-path`, which keeps
them out of the built layers as well as out of the sweep.

## HOME, and why the error names the wrong thing

kaniko resolves `$HOME` and, when it is unset, falls back to looking the current
uid up in `/etc/passwd`. Inside the chroot the agent's own passwd file is not
reachable, so `kaniko-chroot.sh` writes a two-line one. Outside it, the
Containerfile appends a UID 1001 entry and `start-agent.sh` exports `HOME`
before anything runs.

Without either, the first command a pipeline tries fails with:

```
unable to resolve HOME directory: user: unknown userid 0
```

which is an error about `HOME` that is really about NSS. It costs an afternoon
the first time.

## The flags

Set in `rootfs/azdo-agent-build/usr/local/bin/kaniko-build.sh`, and each one is
there for a reason worth keeping.

| flag | why |
|---|---|
| `--no-push` | Unconditional, and a literal so no pipeline variable can turn it back on. kaniko can push; the task holding repository-supplied YAML must never be the task that does. |
| `--destination` | **Not a push target.** kaniko needs a name for the image it assembles even when it is not pushing it. Forbidding this flag would forbid one kaniko requires. |
| `--oci-layout-path` | Not `--tar-path`, which writes a *docker* tarball. The artifact has to be an OCI layout: a format conversion on the way to the registry would change the digest between what was scanned and what lands there. |
| `--cache=true --cache-dir` | The warmed base images. The base cache only works with `--cache=true`, which in turn **refuses to start** under `--no-push` unless a `--cache-repo` is named. |
| `--cache-repo oci:/layercache` | The `oci:` prefix makes it a local path. Without it kaniko runs a push-permission check against the name and fails with no network, blaming a registry nobody asked for. |
| `--reproducible` | Zeroes layer timestamps and history. Memory-hungry: it rewrites layers in memory. |
| `--ignore-path` ×4 | The scratch directories inside the chroot. Without them kaniko deletes the context on the way in and snapshots its own cache into the image. |

## SOURCE_DATE_EPOCH

Taken from the commit being built, falling back to `0` — **never the clock**. A
timestamp that moves is the single most common reason two builds of one revision
disagree.

## What this is not

The forge's contract is explicit that a container runtime is a weaker boundary
than a microVM: the isolation is a namespace, not a hypervisor, and the offline
switches are discipline rather than a device. Its conclusion there was that
`runtime=microvm` is the default for pull-request code and `runtime=container` is
for inputs somebody has decided to trust.

The same caveat applies here and should be read the same way. An ephemeral,
one-shot agent limits the blast radius to a single job, and the build pool holds
no credential — but a pipeline that runs untrusted YAML in this pool is trusting
a namespace.
