#!/usr/bin/env python3
"""Verify the pinned contract and reproduce Apple's generated client."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = json.loads((ROOT / "Generation" / "tools.json").read_text())
VERSION = TOOLS["generator"]["version"]
GENERATOR_COMMIT = TOOLS["generator"]["revision"]
ASSETS = {"openapi.json", "chat-snapshot.schema.json", "activity-event.schema.json", "heartbeat.schema.json", "CHANGELOG.md", "source-commit.txt"}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def verify(directory):
    checksums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([a-f0-9]{64})  ([A-Za-z0-9.-]+)", line)
        if not match or match[2] in checksums:
            raise ValueError("Invalid or duplicate checksum entry")
        checksums[match[2]] = match[1]
    if set(checksums) != ASSETS:
        raise ValueError("Checksum manifest must cover every contract payload exactly once")
    for name, expected in checksums.items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Checksum mismatch: {name}")
    return checksums


def project(node, schemas=None):
    if isinstance(node, list):
        return [project(item, schemas) for item in node]
    if not isinstance(node, dict):
        return node
    if schemas is not None and "anyOf" in node:
        branches = node["anyOf"]
        if any(branch == {"type": "null"} for branch in branches):
            if len(branches) != 2 or set(node) != {"anyOf"}:
                raise ValueError("Unsupported nullable union shape")
            reference = next(branch for branch in branches if branch != {"type": "null"})
            if set(reference) != {"$ref"} or not reference["$ref"].startswith("#/components/schemas/"):
                raise ValueError("Expected a nullable named object reference")
            target = schemas[reference["$ref"].removeprefix("#/components/schemas/")]
            if target.get("type") != "object" or any(key in target for key in ("$ref", "anyOf", "oneOf", "allOf")):
                raise ValueError("Nullable reference must resolve to a plain object")
            return project(dict(target, type=["object", "null"]), schemas)
    result = {key: project(value, schemas) for key, value in node.items() if key != "$schema"}
    if "const" in result:
        result["enum"] = [result.pop("const")]
    return result


def generate(directory):
    cache = ROOT / ".build" / f"openapi-generator-{VERSION}"
    if not cache.exists():
        run("git", "clone", "--depth", "1", "--branch", VERSION,
            "https://github.com/apple/swift-openapi-generator.git", str(cache))
    revision = subprocess.check_output(["git", "-C", str(cache), "rev-parse", "HEAD"], text=True).strip()
    if revision != GENERATOR_COMMIT:
        raise ValueError("Generator checkout does not match pinned commit")
    run("git", "-C", str(cache), "diff", "--exit-code", "HEAD")
    shutil.copyfile(ROOT / TOOLS["generator"]["dependencyLock"], cache / "Package.resolved")
    run("swift", "build", "--package-path", str(cache), "--force-resolved-versions", "-c", "release", "--product", "swift-openapi-generator")
    binary_dir = subprocess.check_output(["swift", "build", "--package-path", str(cache), "-c", "release", "--show-bin-path"], text=True).strip()
    document = json.loads((ROOT / "Contract" / "openapi.json").read_text())
    for name, asset in [("EventChatSnapshot", "chat-snapshot.schema.json"), ("EventActivity", "activity-event.schema.json"), ("EventHeartbeat", "heartbeat.schema.json")]:
        document["components"]["schemas"][name] = project(json.loads((ROOT / "Contract" / asset).read_text()))
    document = project(document, document["components"]["schemas"])
    source = directory / "openapi.json"
    source.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n")
    output = directory / "Generated"
    output.mkdir()
    run(str(pathlib.Path(binary_dir) / "swift-openapi-generator"), "generate", "--mode", "types", "--mode", "client", "--access-modifier", "public", "--naming-strategy", "idiomatic", "--output-directory", str(output), str(source))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", help="Local export directory or contract-vX.Y.Z release tag")
    parser.add_argument("--check", action="store_true", help="Reject stale or manually edited output")
    args = parser.parse_args()
    if args.update and args.check:
        parser.error("--update and --check are mutually exclusive")
    contract = ROOT / "Contract"
    if args.update:
        with tempfile.TemporaryDirectory() as temporary:
            if re.fullmatch(r"contract-v\d+\.\d+\.\d+", args.update):
                source = pathlib.Path(temporary)
                for name in sorted(ASSETS | {"SHA256SUMS"}):
                    url = f"https://github.com/crumble-project/bot/releases/download/{args.update}/{name}"
                    with urllib.request.urlopen(url) as response:
                        (source / name).write_bytes(response.read())
                provenance = {"kind": "release", "tag": args.update}
            else:
                source = pathlib.Path(args.update).resolve(strict=True)
                provenance = {"kind": "local-export"}
            checksums = verify(source)
            version = json.loads((source / "openapi.json").read_text())["info"]["version"]
            if provenance["kind"] == "release" and args.update != f"contract-v{version}":
                raise ValueError("Release tag and contract version differ")
            provenance.update(version=version, sourceCommit=(source / "source-commit.txt").read_text().strip(), checksums=checksums)
            contract.mkdir(exist_ok=True)
            for name in ASSETS | {"SHA256SUMS"}:
                shutil.copyfile(source / name, contract / name)
            (contract / "pin.json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
    checksums = verify(contract)
    package = (ROOT / "Package.swift").read_text()
    for dependency, version in [("swift-openapi-runtime", TOOLS["runtime"]), ("swift-http-types", TOOLS["httpTypes"])]:
        if f'.package(url: "https://github.com/apple/{dependency}", exact: "{version}")' not in package:
            raise ValueError(f"Package.swift does not match the recorded {dependency} version")
    pin = json.loads((contract / "pin.json").read_text())
    if pin["checksums"] != checksums or pin["sourceCommit"] != (contract / "source-commit.txt").read_text().strip():
        raise ValueError("Contract pin does not match assets")
    if pin["version"] != json.loads((contract / "openapi.json").read_text())["info"]["version"]:
        raise ValueError("Contract pin version does not match assets")
    if not re.fullmatch(r"[a-f0-9]{40}", pin["sourceCommit"]):
        raise ValueError("Contract provenance must contain a full source commit")
    if pin["kind"] not in {"release", "local-export"}:
        raise ValueError("Unknown contract provenance kind")
    if pin["kind"] == "release" and pin["tag"] != f'contract-v{pin["version"]}':
        raise ValueError("Pinned release tag does not match contract version")
    target = ROOT / "Sources" / "apfelkern" / "Generated"
    with tempfile.TemporaryDirectory() as temporary:
        output = generate(pathlib.Path(temporary))
        if args.check:
            expected = {path.name: path.read_bytes() for path in output.iterdir()}
            actual = {path.name: path.read_bytes() for path in target.iterdir()} if target.exists() else {}
            if expected != actual:
                raise ValueError("Generated output is stale or manually edited; run python3 scripts/contract.py")
            print("Generated output matches the pinned contract byte-for-byte")
        else:
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(output, target)
    if args.update:
        run("swift", "test", cwd=ROOT)


if __name__ == "__main__":
    main()
