#!/usr/bin/env python3
"""Remove build/test-only Python payload while preserving runtime capability."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


REMOVABLE_DIRECTORY_NAMES = frozenset({"__pycache__", ".pytest_cache", "test", "tests"})
BYTECODE_SUFFIXES = frozenset({".pyc", ".pyo"})
DISTLIB_LAUNCHERS = frozenset(
    {"t32.exe", "t64.exe", "t64-arm.exe", "w32.exe", "w64.exe", "w64-arm.exe"}
)
CPU_ARCHITECTURES = {
    0x01000007: "x64",
    0x0100000C: "arm64",
    0x8664: "x64",
    0xAA64: "arm64",
    62: "x64",
    183: "arm64",
}


def remove_directory(path: Path, stats: dict[str, int]) -> None:
    if not path.is_dir() or path.is_symlink():
        return
    for child in path.rglob("*"):
        if child.is_file() and not child.is_symlink():
            stats["removedBytes"] += child.stat().st_size
            stats["removedFiles"] += 1
    shutil.rmtree(path)
    stats["removedDirectories"] += 1


def remove_file(path: Path, stats: dict[str, int]) -> None:
    if not path.is_file() or path.is_symlink():
        return
    stats["removedBytes"] += path.stat().st_size
    stats["removedFiles"] += 1
    path.unlink()


def native_kind(path: Path) -> tuple[str, set[str]] | None:
    with path.open("rb") as handle:
        data = handle.read(4096)
    if len(data) < 20:
        return None

    magic = data[:4]
    thin_mach = {
        b"\xfe\xed\xfa\xce": "big",
        b"\xfe\xed\xfa\xcf": "big",
        b"\xce\xfa\xed\xfe": "little",
        b"\xcf\xfa\xed\xfe": "little",
    }
    if magic in thin_mach:
        cpu = int.from_bytes(data[4:8], thin_mach[magic])
        return "Mach-O", {CPU_ARCHITECTURES.get(cpu, f"cpu-{cpu}")}

    fat_mach = {
        b"\xca\xfe\xba\xbe": ("big", 20),
        b"\xbe\xba\xfe\xca": ("little", 20),
        b"\xca\xfe\xba\xbf": ("big", 32),
        b"\xbf\xba\xfe\xca": ("little", 32),
    }
    if magic in fat_mach:
        endian, entry_size = fat_mach[magic]
        count = int.from_bytes(data[4:8], endian)
        if count < 1 or count > 32 or len(data) < 8 + count * entry_size:
            return "Mach-O", {"malformed-fat-header"}
        architectures = set()
        for index in range(count):
            offset = 8 + index * entry_size
            cpu = int.from_bytes(data[offset : offset + 4], endian)
            architectures.add(CPU_ARCHITECTURES.get(cpu, f"cpu-{cpu}"))
        return "Mach-O", architectures

    if magic == b"\x7fELF":
        endian = "little" if data[5] == 1 else "big"
        machine = int.from_bytes(data[18:20], endian)
        return "ELF", {CPU_ARCHITECTURES.get(machine, f"machine-{machine}")}

    if data[:2] == b"MZ":
        pe_offset = int.from_bytes(data[0x3C:0x40], "little")
        if pe_offset + 6 > len(data):
            with path.open("rb") as handle:
                handle.seek(pe_offset)
                pe_header = handle.read(6)
        else:
            pe_header = data[pe_offset : pe_offset + 6]
        if pe_header[:4] == b"PE\0\0":
            machine = int.from_bytes(pe_header[4:6], "little")
            return "PE", {CPU_ARCHITECTURES.get(machine, f"machine-{machine}")}

    return None


def verify_native_architecture(root: Path, platform: str, target_arch: str) -> dict[str, int]:
    expected_format = {"darwin": "Mach-O", "linux": "ELF", "win32": "PE"}[platform]
    checked = []
    mismatches = []
    universal_files = 0

    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        kind = native_kind(path)
        if kind is None:
            continue
        file_format, architectures = kind
        checked.append(path)
        if len(architectures) > 1:
            universal_files += 1
        if file_format != expected_format or target_arch not in architectures:
            mismatches.append(
                {
                    "path": str(path.relative_to(root)),
                    "format": file_format,
                    "architectures": sorted(architectures),
                }
            )

    if not checked:
        raise SystemExit("Python runtime architecture verification found no native files")
    if mismatches:
        raise SystemExit(
            "Python runtime architecture mismatch: "
            + json.dumps(mismatches[:20], ensure_ascii=False)
        )
    return {
        "nativeFilesChecked": len(checked),
        "nativeTargetArchitecture": target_arch,
        "nativeUniversalFiles": universal_files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--platform", required=True, choices=("darwin", "linux", "win32"))
    parser.add_argument("--arch", required=True, choices=("arm64", "x64"))
    args = parser.parse_args()

    root = args.root.resolve()
    if not root.is_dir():
        raise SystemExit(f"Python runtime root does not exist: {root}")

    stats = {
        "removedBytes": 0,
        "removedDirectories": 0,
        "removedFiles": 0,
    }

    removable_directories = sorted(
        (
            path
            for path in root.rglob("*")
            if path.is_dir() and not path.is_symlink() and path.name in REMOVABLE_DIRECTORY_NAMES
        ),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for directory in removable_directories:
        remove_directory(directory, stats)

    for file in list(root.rglob("*")):
        if file.is_file() and not file.is_symlink() and file.suffix.lower() in BYTECODE_SUFFIXES:
            remove_file(file, stats)

    for developer_tree in root.rglob("pymupdf/mupdf-devel"):
        remove_directory(developer_tree, stats)

    keep_launchers: set[str]
    if args.platform == "win32" and args.arch == "x64":
        keep_launchers = {"t64.exe", "w64.exe"}
    elif args.platform == "win32" and args.arch == "arm64":
        keep_launchers = {"t64-arm.exe", "w64-arm.exe"}
    else:
        keep_launchers = set()

    for distlib in root.rglob("pip/_vendor/distlib"):
        if not distlib.is_dir():
            continue
        for launcher_name in DISTLIB_LAUNCHERS - keep_launchers:
            remove_file(distlib / launcher_name, stats)

    forbidden_directories = [
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_dir() and path.name in REMOVABLE_DIRECTORY_NAMES
    ]
    remaining_bytecode = [
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in BYTECODE_SUFFIXES
    ]
    foreign_launchers = []
    for distlib in root.rglob("pip/_vendor/distlib"):
        foreign_launchers.extend(
            str(path.relative_to(root))
            for path in distlib.glob("*.exe")
            if path.name in DISTLIB_LAUNCHERS and path.name not in keep_launchers
        )

    if forbidden_directories or remaining_bytecode or foreign_launchers:
        raise SystemExit(
            "Python runtime pruning failed closed: "
            + json.dumps(
                {
                    "forbiddenDirectories": forbidden_directories[:20],
                    "foreignLaunchers": foreign_launchers[:20],
                    "remainingBytecode": remaining_bytecode[:20],
                },
                ensure_ascii=False,
            )
        )

    native_stats = verify_native_architecture(root, args.platform, args.arch)

    print(
        json.dumps(
            {
                "status": "pruned",
                "platform": args.platform,
                "arch": args.arch,
                **stats,
                **native_stats,
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
