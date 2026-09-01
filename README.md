# Trusted Build Agents

Ephemeral, self-hosted **Azure DevOps agent images** on the Infrashift trusted
UBI9 line. They run YAML pipelines that build OCI images with
[kaniko](https://github.com/osscontainertools/kaniko) and devcontainer images
with [envbuilder](https://github.com/coder/envbuilder).

Images are published to `ghcr.io/infrashift/trusted-build-agents`, in the same
three namespaces the sibling repos use: `development/`, `trusted/`,
`quarantine/`. **No `:latest`, ever.**

## The split

There are two agent images, and the separation between them is the design.

| Image | Pool | Carries | Cannot |
|---|---|---|---|
| `azdo-agent-build` | `Trusted-Build` | the agent, `kaniko-executor`, `envbuilder`, git | reach a registry — it holds no credential and contains no registry client |
| `azdo-agent-publish` | `Trusted-Publish` | the agent, `skopeo`, `registry` | author an image — no kaniko, no envbuilder, no compiler |

> the build task cannot reach a registry, the signer cannot move what it signed,
> and the publisher cannot author what it pushes — **because none of them
> contains the tool**, rather than because a script was asked not to.
>
> — `runner/CONTAINER-CONTRACT.md`, sshadowforge

In Azure DevOps a job cannot choose its image; it chooses a **pool**. So one pool
maps to exactly one image, and the PAT for each pool is scoped to that pool.
`image-contract.json` asserts the required/forbidden tool lists against the bytes
of the built image, because `microdnf` resolves a dependency closure and a
transitive skopeo would breach the boundary silently.

## The pipeline shape

```
stage Build     pool: Trusted-Build
  kaniko-build.sh ctx Containerfile myapp:1.2.3 $(Build.ArtifactStagingDirectory)
  publish artifact  ->  image.oci

stage Publish   pool: Trusted-Publish     dependsOn: Build
  download artifact
  push-oci.sh $(Pipeline.Workspace)/image.oci nexus.example.com/oci/myapp:1.2.3
```

The build stage stages an OCI layout and never pushes it. The publish stage holds
the Nexus OAuth2 client and pushes what it was handed, verifying the digest
before and after. The destination repository is ALLOW_ONCE, so an identical
re-push succeeds and a differing one fails hard.

## Layout

| path | what |
|---|---|
| `versions.json` | the sovereign pin file — every digest, commit and tarball hash |
| `schemas/versions.schema.json` | its shape |
| `image-contract.json` | what each image must and must not contain |
| `Containerfiles/` | one `.Containerfile` per image |
| `rootfs/` | scripts baked into the images, mirroring their in-container paths |
| `scripts/` | lint, validation and build-leg helpers |
| `.github/pdp/policies.rego` | the policy decision point |
| `docs/kaniko-chroot.md` | why kaniko needs a chroot, and the three stubs inside it |
| `docs/envbuilder-output.md` | why envbuilder is not a drop-in image builder |

## Working here

```bash
make -f Ops.mk validate                 # everything; run before proposing anything
make -f Ops.mk list-images
make -f Ops.mk verify-pins              # resolve every pin live and diff it
make -f Ops.mk build IMAGE=azdo-agent-build ARCH=amd64
bash scripts/lint-image-contract.sh --image azdo-agent-build <ref>
```

`CLAUDE.md` documents the conventions that are load-bearing, including the two
deliberate departures from `trusted-service-containers`: the runtime base is
`ubi9-minimal` rather than `ubi9-micro`, and `azdo-agent-build` is run as
container-root because kaniko needs `CAP_SYS_CHROOT`.

## Running an agent

The images are ephemeral by design: `config.sh --unattended`, `run.sh --once`,
deregister from a trap on every exit path. One job per container, then it goes.

```
AZP_URL=https://dev.azure.com/ryancraig
AZP_TOKEN=<PAT scoped to this pool>
AZP_POOL=Trusted-Build
AZP_AGENT_NAME=<defaults to the hostname>
```

Launching a replacement after each job is the scaler's problem, not the image's —
the image is scaler-agnostic and works under KEDA, Nomad dispatch, or a plain
restart policy.

## Status

Both images are onboarded with `enforcement: "observe"`. That still computes,
records and publishes every violation and still routes to `quarantine`; it only
stops the pipeline hard-failing while day-one CVE triage happens. It is **not** a
route into `trusted/`.

Signing is phase 2. When it lands it will be a third image and a third pool,
carrying cosign and no skopeo — because the signer must not be able to move what
it signed.
