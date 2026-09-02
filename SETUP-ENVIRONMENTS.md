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

## The repository settings the workflows assume

The workflows do not create any of this, and none of it is a repository default.
`gh` commands below assume `REPO=infrashift/trusted-build-agents`.

**An environment that exists is not an environment that is configured.** GitHub
creates one automatically the first time a workflow run names it, with an empty
protection rule set — so `Build-Actor` and `Release-Actor` appear on their own
after the first push and look done. The `environment:` binding still isolates
the secrets at that point, but nothing else constrains them.

### The three environments and their secrets

```bash
for actor in Build-Actor Review-Actor Release-Actor; do
  gh api "repos/$REPO/environments/$actor" -X PUT >/dev/null
done
```

Each holds `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` — the same two names in all
three, different values. Setting them under one name per environment is the whole
isolation mechanism, so resist adding a disambiguating suffix.

```bash
gh secret set COSIGN_PRIVATE_KEY --env Build-Actor --repo "$REPO" \
  < ~/.config/cosign/infrashift/trusted-build-agents/build.key
```

### Release-Actor is restricted to the default branch

Without this, a pull request branch can reach the release signing key by naming
the environment, which defeats the split the three keys exist to create.

```bash
gh api "repos/$REPO/environments/Release-Actor" -X PUT \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null
gh api "repos/$REPO/environments/Release-Actor/deployment-branch-policies" \
  -X POST -f name=main -f type=branch >/dev/null
```

`Build-Actor` and `Review-Actor` stay unrestricted: both run on pull requests, so
a branch policy on either would stop the pipeline doing its job.

### A ruleset on the default branch

Branch *protection* is the older API and returns `404 Branch not protected` even
on repositories that are fully covered by a ruleset — do not read that as
evidence of anything. The `trusted-*` repositories use rulesets.

```bash
gh api "repos/$REPO/rulesets" -X POST --input - <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "require_extra_approval_for_unattributed_changes": true,
        "allowed_merge_methods": ["merge", "squash", "rebase"]
      } },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "pr-gate" },
          { "context": "build/gate" }
        ]
      } }
  ]
}
JSON
```

Two details are load-bearing. `bypass_actors` is empty, including of
administrators: a rule an admin can step around is a rule that will be stepped
around at the one moment it matters. And the required contexts are the **gate**
jobs, `pr-gate` and `build/gate`, not the individual build legs — the gates are
declared `if: always()` and fail when any dependency did, so they hold whether a
leg failed or was skipped, whereas requiring a matrix leg by name blocks forever
on a PR whose paths filter skipped it.

`required_approving_review_count` is `0` because this repository's review step is
`review.yml` verifying signed evidence, not a human clicking approve.
`require_extra_approval_for_unattributed_changes` stays `true`: it is what covers
a commit pushed under an identity GitHub cannot attribute to the PR author.

### Actions may not write, and may not approve

```bash
gh api "repos/$REPO/actions/permissions/workflow" -X PUT \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```

`read` is the current default for new repositories and every `trusted-*` repo
already matches, so this usually confirms rather than changes. Assert it anyway
— it is an organisation-level setting that can be changed out from under a
repository, and a `write` default would hand every workflow in the repository a
token that can push to `main`.

### DEPARTURE: secret scanning on, unlike the siblings

The other `trusted-*` repositories have secret scanning and push protection
disabled. Turn both on here:

```bash
gh api "repos/$REPO" -X PATCH \
  -F 'security_and_analysis[secret_scanning][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
```

Both are free on public repositories, and they cover the case `scan-secrets.sh`
structurally cannot: it runs gitleaks with `--no-git` against the working tree of
a checkout, so it never reads history and never sees a push. This repository
generates three private keys into its own root as step one of setup, which is
exactly when a stray `git add -f` happens.


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
