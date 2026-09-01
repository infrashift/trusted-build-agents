#!/usr/bin/env bash
# Resolve every pin LIVE and compare it to what versions.json records.
#
# NOT a gate. A pin that no longer resolves is not necessarily wrong -- a tag can
# be retired while the digest it named stays pullable -- but it is always worth
# knowing before a build discovers it at 3am. Run it from drift detection, and
# read the output.
set -euo pipefail

command -v skopeo >/dev/null || { echo "skopeo is required" >&2; exit 1; }
command -v jq     >/dev/null || { echo "jq is required" >&2; exit 1; }

rc=0
note() { printf '  %s\n' "$*"; }

echo "bases:"
while read -r key; do
  image=$(jq -r --arg k "$key" '.bases[$k].image' versions.json)
  for arch in amd64 arm64; do
    want=$(jq -r --arg k "$key" --arg a "$arch" '.bases[$k][$a].digest' versions.json)
    # The index digest, per-arch child. `skopeo inspect --raw' on the index gives
    # the child list; docker inspect would give the LOCAL architecture's, which is
    # the classic way to pin the wrong one.
    got=$(skopeo inspect --raw "docker://${image}:latest" 2>/dev/null \
      | jq -r --arg a "$arch" '.manifests[] | select(.platform.architecture==$a and .platform.os=="linux") | .digest' | head -1)
    if [ -z "$got" ]; then
      note "$key/$arch: could not resolve ${image}:latest"; rc=1
    elif [ "$got" != "$want" ]; then
      note "$key/$arch: DRIFT  recorded $want  live $got"; rc=1
    else
      note "$key/$arch: ok"
    fi
  done
done < <(jq -r '.bases | keys[]' versions.json)

echo "sources:"
while read -r key; do
  url=$(jq -r --arg k "$key" '.sources[$k].url' versions.json)
  ref=$(jq -r --arg k "$key" '.sources[$k].ref' versions.json)
  want=$(jq -r --arg k "$key" '.sources[$k].commit' versions.json)
  got=$(git ls-remote "$url" "refs/tags/${ref}^{}" 2>/dev/null | cut -f1)
  [ -n "$got" ] || got=$(git ls-remote "$url" "refs/tags/${ref}" 2>/dev/null | cut -f1)
  if [ -z "$got" ]; then
    note "$key: tag $ref not found at $url"; rc=1
  elif [ "$got" != "$want" ]; then
    note "$key: TAG MOVED  recorded $want  live $got  -- this is exactly why we pin the commit"; rc=1
  else
    note "$key: ok ($ref -> $want)"
  fi
done < <(jq -r '.sources | keys[]' versions.json)

exit "$rc"
