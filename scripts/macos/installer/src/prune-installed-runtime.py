#!/usr/bin/env python3
"""Write/consume an immutable iGemini runtime manifest for clean pkg upgrades."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path, PurePosixPath
from typing import NoReturn


FORMAT_VERSION = 1
MANIFEST_NAME = ".igemini-runtime-manifest.json"
REQUIRED_PATHS = {
    MANIFEST_NAME,
    "prune-installed-runtime.py",
    "runtime/node/bin/node",
    "start-web.sh",
    "claudecodeui/dist-server/server/index.js",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"iGemini runtime manifest error: {message}")


def normalized_relative(path: str) -> str:
    value = path.replace(os.sep, "/")
    if value.startswith("./"):
        value = value[2:]
    pure = PurePosixPath(value)
    if not value or pure.is_absolute() or ".." in pure.parts:
        fail(f"unsafe relative path: {path!r}")
    return pure.as_posix()


def iter_payload_paths(root: Path):
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        for name in sorted(dirnames):
            path = Path(dirpath, name)
            if path.is_symlink():
                yield normalized_relative(os.path.relpath(path, root))
        for name in sorted(filenames):
            path = Path(dirpath, name)
            yield normalized_relative(os.path.relpath(path, root))


def write_manifest(root_arg: str, output_arg: str) -> None:
    root = Path(root_arg).resolve(strict=True)
    output = Path(output_arg)
    paths = set(iter_payload_paths(root))
    paths.add(MANIFEST_NAME)
    missing = REQUIRED_PATHS - paths
    if missing:
        fail(f"payload missing required paths: {sorted(missing)}")
    payload = {"format": FORMAT_VERSION, "paths": sorted(paths)}
    output.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(json.dumps({"status": "manifest-written", "paths": len(paths)}, separators=(",", ":")))


def load_manifest(manifest: Path) -> set[str]:
    try:
        payload = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {manifest}: {exc}")
    if payload.get("format") != FORMAT_VERSION or not isinstance(payload.get("paths"), list):
        fail("unsupported manifest format")
    allowed = {normalized_relative(item) for item in payload["paths"] if isinstance(item, str)}
    missing = REQUIRED_PATHS - allowed
    if missing or len(allowed) < 1000:
        fail(f"manifest incomplete: paths={len(allowed)} missing={sorted(missing)}")
    return allowed


def remove_file(path: Path) -> int:
    try:
        size = path.lstat().st_size
        path.unlink()
        return size
    except FileNotFoundError:
        return 0


def prune_runtime(root_arg: str, manifest_arg: str) -> None:
    root = Path(root_arg).resolve(strict=True)
    manifest = Path(manifest_arg).resolve(strict=True)
    if manifest.parent != root or manifest.name != MANIFEST_NAME:
        fail("manifest must be the fixed file directly under the runtime root")
    allowed = load_manifest(manifest)
    removed_files = 0
    removed_dirs = 0
    removed_bytes = 0

    for dirpath, dirnames, filenames in os.walk(root, topdown=False, followlinks=False):
        for name in filenames:
            path = Path(dirpath, name)
            rel = normalized_relative(os.path.relpath(path, root))
            if rel not in allowed:
                removed_bytes += remove_file(path)
                removed_files += 1
        for name in dirnames:
            path = Path(dirpath, name)
            rel = normalized_relative(os.path.relpath(path, root))
            if path.is_symlink():
                if rel not in allowed:
                    removed_bytes += remove_file(path)
                    removed_files += 1
                continue
            try:
                path.rmdir()
                removed_dirs += 1
            except (FileNotFoundError, OSError):
                pass

    print(
        json.dumps(
            {
                "status": "runtime-pruned",
                "allowedPaths": len(allowed),
                "removedFiles": removed_files,
                "removedDirectories": removed_dirs,
                "removedBytes": removed_bytes,
            },
            separators=(",", ":"),
        )
    )


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "--write-manifest":
        write_manifest(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) == 4 and sys.argv[1] == "--prune":
        prune_runtime(sys.argv[2], sys.argv[3])
        return
    fail("usage: prune-installed-runtime.py --write-manifest ROOT OUTPUT | --prune ROOT MANIFEST")


if __name__ == "__main__":
    main()
