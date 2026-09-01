# One-time setup

Nothing in this repository ships a key. These are the steps that have to happen
once, by hand, before the workflows can run.

## Three GitHub Environments, three keys, one secret name

`build.yml`, `review.yml` and `release.yml` bind to `Build-Actor`,
`Review-Actor` and `Release-Actor` respectively. Each environment holds a
**different** cosign key under the **same** secret name. The isolation is
entirely the `environment:` binding — that is the mechanism, so do not add a
second secret name as a "safety net": it would make one key reachable from two
jobs, which is exactly the thing being prevented.

```bash
for actor in build review release; do
  cosign generate-key-pair --output-key-prefix "$actor"
  # $actor.key  -> the environment secret COSIGN_PRIVATE_KEY
  #                (COSIGN_PASSWORD holds the password you were prompted for)
  # $actor.pub  -> commit to .github/pdp/public-keys/$actor.pub
done
```

Commit only the `.pub` files. `.gitignore` refuses `*.key`, and it should stay
that way: the sibling `trusted-base-oci-images` has a `temp-delete/` directory
holding three private keys, and the only reason that is not an incident is that
the same ignore rule kept them out of the index.

## The private halves do not stay here

The loop above writes all six files to the repository root. Load each `.key`
into its environment as `COSIGN_PRIVATE_KEY`, then **move it out of the working
tree** — one directory per repository, because the keys are not shared between
them:

```bash
dest=~/.config/cosign/infrashift/trusted-build-agents
mkdir -p "$dest" && chmod 700 "$dest"
mv build.key review.key release.key "$dest/" && chmod 600 "$dest"/*.key
```

`make -f Ops.mk validate` fails until you do. `scan-secrets.sh` runs gitleaks
with `--no-git`, so it reads the working tree and `.gitignore` hides nothing from
it — being un-committable is not the same as being absent. That is the intended
strictness and not something to allowlist away in `.gitleaks.toml`: the
repository root is a container build **context**, so a private key sitting in it
is one `podman build` away from being baked into a layer, which no ignore rule
prevents.

`review.yml` verifies the build actor's signatures against
`.github/pdp/public-keys/build.pub`, so **that file must exist before Review can
pass**. Until the keys are generated, expect Review to fail at the verify step.

## Pinning cosign v2, not v3

`tools.lock` pins `COSIGN_VERSION=v2.6.1` to stay interoperable with
`trusted-base-images` and `trusted-service-containers`. v3 defaults to
`--new-bundle-format=true` and writes attestations as OCI referrers; v2 writes
the legacy `sha256-<digest>.att` tags. Migrate all three repos together, never
one at a time.

## Azure DevOps: two pools, two PATs

The capability split is only real if one pool maps to one image, and the PAT for
each pool is scoped to that pool alone.

| Pool | Image | PAT scope |
|---|---|---|
| `Trusted-Build` | `azdo-agent-build` | Agent Pools (read, manage) on this pool only |
| `Trusted-Publish` | `azdo-agent-publish` | Agent Pools (read, manage) on this pool only |

Create both under **Organization settings → Agent pools**, then give each
deployment its own `AZP_TOKEN`. A single organisation-wide PAT would let a
compromised build agent register itself into the publish pool, which is the one
move the whole arrangement exists to prevent.

## The Nexus OCI client

`push-oci.sh` reads `SFD_OCI_CLIENT_ID` and `SFD_OCI_CLIENT_SECRET`. Put them in
an Azure DevOps **variable group** scoped to the publish stage only — never on
the pipeline, which would put them in reach of the job running repository YAML.

The OCI repository is **ALLOW_ONCE**: a pushed tag can never be rewritten. That
is a property of the repository configuration in Nexus, not of these scripts, and
`push-oci.sh` is written to match it.

## Running an agent

```bash
podman run --rm \
  -e AZP_URL=https://dev.azure.com/ryancraig \
  -e AZP_TOKEN="$PAT" \
  -e AZP_POOL=Trusted-Build \
  --user root \
  ghcr.io/infrashift/trusted-build-agents/trusted/azdo-agent-build:<sha7>
```

`--user root` is required for the **build** pool only, and only because kaniko
needs `CAP_SYS_CHROOT`; it is in the default capability set, so nothing else is
granted. Do not add `--privileged`, do not add capabilities, do not mount a host
path. The publish pool runs as the image's own `USER 1001`.

See `docs/kaniko-chroot.md` for why the exemption exists and what it does not
include.
