# Public keys

Three cosign public keys live here — `build.pub`, `review.pub`, `release.pub` —
one per GitHub Environment. They are **not** in this repository yet: generate
them as part of the one-time setup in `SETUP-ENVIRONMENTS.md` and commit only the
`.pub` halves.

`review.yml` verifies the build actor's evidence against `build.pub`, so Review
will fail at the verify step until that file exists. That is the correct
behaviour — a review that passed without a key to check against would be
verifying nothing.

Private keys never come here. `.gitignore` refuses `*.key` and `*.pem`.
