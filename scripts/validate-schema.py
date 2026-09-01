#!/usr/bin/env python3
"""Validate versions.json against the schema, then the cross-references the schema cannot express.

JSON Schema checks the SHAPE of one object at a time. Everything below is a
relationship BETWEEN objects -- an image naming a base that does not exist, a
pin that has drifted outside its own track, a Containerfile on disk that no
entry references. Those are exactly the errors that survive a schema pass and
then fail ten minutes into a build matrix, so they are checked here instead.
"""
import json
import os
import re
import sys

import jsonschema

FAIL = []


def err(msg):
    FAIL.append(msg)


def main():
    versions = json.load(open("versions.json"))
    schema = json.load(open("schemas/versions.schema.json"))

    # --- Shape ------------------------------------------------------------
    validator = jsonschema.Draft202012Validator(schema)
    for e in sorted(validator.iter_errors(versions), key=lambda e: list(e.path)):
        err("schema: {}: {}".format("/".join(str(p) for p in e.path) or "<root>", e.message))
    if FAIL:
        # Cross-reference checks below index into a structure the schema just
        # rejected; running them would report confusing follow-on errors.
        return report()

    bases = versions["bases"]
    toolchains = versions["toolchains"]
    sources = versions["sources"]
    agents = versions["agents"]
    images = versions["images"]

    # --- A pin must lie inside its own track ------------------------------
    # The track is the reviewed statement of where this pin may move. A ref
    # outside it means someone bumped the version and left the policy behind.
    for key, src in sources.items():
        if not re.match(src["track"], src["ref"]):
            err("sources.{}: ref {!r} does not match its own track {!r}".format(
                key, src["ref"], src["track"]))

    for key, agent in agents.items():
        if not re.match(agent["track"], agent["version"]):
            err("agents.{}: version {!r} does not match its own track {!r}".format(
                key, agent["version"], agent["track"]))
        for arch in ("amd64", "arm64"):
            if agent[arch]["sha256"] == agent["amd64"]["sha256"] and arch != "amd64":
                err("agents.{}: {} and amd64 declare the SAME tarball sha256; "
                    "one of them was copied and not replaced".format(key, arch))

    # --- Every reference resolves ----------------------------------------
    for name, img in images.items():
        if img["base"] not in bases:
            err("images.{}: base {!r} is not in `bases`".format(name, img["base"]))
        elif bases[img["base"]]["role"] != "runtime":
            err("images.{}: base {!r} has role {!r}; an image must be built on a "
                "base declared `runtime`".format(
                    name, img["base"], bases[img["base"]]["role"]))

        if img["toolchain"] not in toolchains:
            err("images.{}: toolchain {!r} is not in `toolchains`".format(name, img["toolchain"]))
        if img["agent"] not in agents:
            err("images.{}: agent {!r} is not in `agents`".format(name, img["agent"]))

        for tool in img["goTools"]:
            if tool not in sources:
                err("images.{}: goTools names {!r}, which is not in `sources`".format(name, tool))

        # Every arch the image claims must have a pin on every input it uses.
        for arch in img["arches"]:
            if arch not in bases.get(img["base"], {}):
                err("images.{}: base {} has no {} digest".format(name, img["base"], arch))
            if arch not in toolchains.get(img["toolchain"], {}):
                err("images.{}: toolchain {} has no {} digest".format(name, img["toolchain"], arch))
            if arch not in agents.get(img["agent"], {}):
                err("images.{}: agent {} has no {} tarball hash".format(name, img["agent"], arch))

    # --- Pools are a capability boundary, so two images must not share one --
    # Two images in one pool means a pipeline job asking for that pool gets
    # whichever agent registered first, and the build/publish split silently
    # stops being a split.
    seen = {}
    for name, img in images.items():
        pool = img["pool"]
        if pool in seen:
            err("images.{} and images.{} both declare pool {!r}; the pool IS the "
                "capability boundary in Azure DevOps and cannot be shared".format(
                    seen[pool], name, pool))
        seen[pool] = name

    # --- Containerfiles: declared <-> on disk -----------------------------
    declared = {img["containerfile"] for img in images.values()}
    on_disk = {
        os.path.join("Containerfiles", f)
        for f in os.listdir("Containerfiles")
        if f.endswith(".Containerfile")
    }
    for p in sorted(declared - on_disk):
        err("{}: declared in versions.json but missing on disk".format(p))
    for p in sorted(on_disk - declared):
        err("{}: exists on disk but no versions.json entry references it".format(p))

    # --- image-contract.json covers exactly these images ------------------
    contract = json.load(open("image-contract.json"))
    contract_images = set(contract["images"])
    for name in sorted(set(images) - contract_images):
        err("images.{}: has no entry in image-contract.json; an image whose "
            "capability boundary is unasserted is one dependency away from "
            "quietly gaining a tool".format(name))
    for name in sorted(contract_images - set(images)):
        err("image-contract.json: describes {!r}, which is not in versions.json".format(name))

    return report()


def report():
    if FAIL:
        for m in FAIL:
            print("error: {}".format(m), file=sys.stderr)
        print("\n{} problem(s) in versions.json".format(len(FAIL)), file=sys.stderr)
        return 1
    print("OK: versions.json passes schema and cross-reference checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
