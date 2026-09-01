#!/usr/bin/env bash
# Every backticked path named in the docs must resolve on disk.
#
# The direct fix for a failure mode the sibling repo shipped: documentation cards
# citing four files that were never created. Prose that names a path nobody can
# open is worse than no prose, because it reads as evidence that the thing exists.
#
# SCOPE, deliberately narrow. Only tokens ending in a known repository extension
# are checked. A bare basename (`push-oci.sh') is resolved by searching the tree,
# because these documents refer to scripts by name far more often than by full
# path and requiring the full path everywhere would make them unreadable.
# Directory-shaped tokens are NOT checked: `trusted/' is a registry namespace and
# `layercache/' is a directory inside a staged artifact, and neither is a path in
# this repository.
set -euo pipefail

python3 - <<'PY'
import os, re, sys

DOCS = ['CLAUDE.md', 'README.md']
for root, _, files in os.walk('docs'):
    DOCS += [os.path.join(root, f) for f in files if f.endswith('.md')]

EXTS = ('sh', 'json', 'md', 'rego', 'yml', 'yaml', 'mk', 'lock', 'Containerfile')
TOKEN = re.compile(r'`([A-Za-z0-9_.][A-Za-z0-9_./-]*\.(?:' + '|'.join(EXTS) + r'))`')

# Paths inside the SIBLING repositories are referenced on purpose and are not
# checkable from here. Listing them explicitly, rather than loosening the regex,
# keeps the check strict for everything else.
EXTERNAL_PREFIXES = ('runner/', 'golden/', 'containerfiles/', 'terraform/', '.ai/')

# Names that belong to the wider world rather than to this tree.
EXTERNAL_NAMES = {'devcontainer.json', 'go.mod', 'go.sum'}

# Index every file in the repo by basename, so a document can say `push-oci.sh'
# without spelling out four directories.
by_name = {}
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules')]
    for f in files:
        by_name.setdefault(f, os.path.join(root, f)[2:])

fail = []
for doc in DOCS:
    if not os.path.exists(doc):
        continue
    for n, line in enumerate(open(doc), 1):
        for m in TOKEN.finditer(line):
            p = m.group(1)
            if p.startswith(EXTERNAL_PREFIXES) or p in EXTERNAL_NAMES:
                continue
            if '/' in p:
                if not os.path.exists(p):
                    fail.append(f"{doc}:{n}: names `{p}`, which does not exist")
            elif p not in by_name:
                fail.append(f"{doc}:{n}: names `{p}`, and no file with that name "
                            f"exists anywhere in the repository")

if fail:
    for m in fail:
        print(f"error: {m}", file=sys.stderr)
    print(f"\n{len(fail)} broken path reference(s)", file=sys.stderr)
    sys.exit(1)
print(f"OK: every backticked path in {len(DOCS)} document(s) resolves")
PY
