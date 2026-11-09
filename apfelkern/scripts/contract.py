#!/usr/bin/env python3
"""Copy the bot contract and reproduce Apple's generated client."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = json.loads((ROOT / "Generation" / "tools.json").read_text())
VERSION = TOOLS["generator"]["version"]
GENERATOR_COMMIT = TOOLS["generator"]["revision"]
ASSETS = {"openapi.json", "chat-snapshot.schema.json", "group-chat-snapshot.schema.json", "activity-event.schema.json", "heartbeat.schema.json", "desktop-control.schema.json"}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def is_nullable_union(node):
    return isinstance(node, dict) and {"type": "null"} in node.get("anyOf", []) and len(node["anyOf"]) > 2


def project(node, schemas=None):
    if isinstance(node, list):
        return [project(item, schemas) for item in node]
    if not isinstance(node, dict):
        return node
    if schemas is not None and "anyOf" in node:
        branches = node["anyOf"]
        if any(branch == {"type": "null"} for branch in branches):
            if set(node) != {"anyOf"}:
                raise ValueError("Unsupported nullable union shape")
            references = [branch for branch in branches if branch != {"type": "null"}]
            if len(references) > 1:
                return {"anyOf": project(references, schemas)}
            reference = references[0]
            if set(reference) != {"$ref"} or not reference["$ref"].startswith("#/components/schemas/"):
                raise ValueError("Expected a nullable named object reference")
            target = schemas[reference["$ref"].removeprefix("#/components/schemas/")]
            if target.get("type") != "object" or any(key in target for key in ("$ref", "anyOf", "oneOf", "allOf")):
                raise ValueError("Nullable reference must resolve to a plain object")
            return project(dict(target, type=["object", "null"]), schemas)
    result = {key: project(value, schemas) for key, value in node.items() if key != "$schema"}
    if schemas is not None and "required" in result and isinstance(node.get("properties"), dict):
        # The generator has no nullable multi-branch union, so null decodes as an absent property.
        result["required"] = [key for key in result["required"] if not is_nullable_union(node["properties"].get(key))]
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
    for name, asset in [("EventChatSnapshot", "chat-snapshot.schema.json"), ("EventGroupChatSnapshot", "group-chat-snapshot.schema.json"), ("EventActivity", "activity-event.schema.json"), ("EventHeartbeat", "heartbeat.schema.json"), ("EventDesktopControl", "desktop-control.schema.json")]:
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
    parser.add_argument("--update", type=pathlib.Path, help="Directory with the contract files, such as bot/openapi")
    parser.add_argument("--check", action="store_true", help="Reject stale or manually edited output")
    args = parser.parse_args()
    if args.update and args.check:
        parser.error("--update and --check are mutually exclusive")
    if args.update:
        for name in ASSETS:
            shutil.copyfile(args.update / name, ROOT / "Contract" / name)
    package = (ROOT / "Package.swift").read_text()
    for dependency, version in [("swift-openapi-runtime", TOOLS["runtime"]), ("swift-http-types", TOOLS["httpTypes"])]:
        if f'.package(url: "https://github.com/apple/{dependency}", exact: "{version}")' not in package:
            raise ValueError(f"Package.swift does not match the recorded {dependency} version")
    target = ROOT / "Sources" / "apfelkern" / "Generated"
    with tempfile.TemporaryDirectory() as temporary:
        output = generate(pathlib.Path(temporary))
        if args.check:
            expected = {path.name: path.read_bytes() for path in output.iterdir()}
            actual = {path.name: path.read_bytes() for path in target.iterdir()} if target.exists() else {}
            if expected != actual:
                raise ValueError("Generated output is stale or manually edited; run python3 scripts/contract.py")
            print("Generated output matches the contract byte-for-byte")
        else:
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(output, target)
    if args.update:
        run("swift", "test", cwd=ROOT)


if __name__ == "__main__":
    main()
