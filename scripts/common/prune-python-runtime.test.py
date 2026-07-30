#!/usr/bin/env python3
"""Regression tests for bundled Python native-binary inspection."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("prune-python-runtime.py")
SPEC = importlib.util.spec_from_file_location("prune_python_runtime", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeKindTests(unittest.TestCase):
    def inspect(self, payload: bytes):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "sample.bin"
            binary.write_bytes(payload)
            return MODULE.native_kind(binary)

    def test_mach_o_fat64_uses_32_byte_entries(self) -> None:
        def entry(cpu: int) -> bytes:
            return (
                cpu.to_bytes(4, "big")
                + (0).to_bytes(4, "big")
                + (0).to_bytes(8, "big")
                + (0).to_bytes(8, "big")
                + (0).to_bytes(4, "big")
                + (0).to_bytes(4, "big")
            )

        payload = (
            b"\xca\xfe\xba\xbf"
            + (2).to_bytes(4, "big")
            + entry(0x01000007)
            + entry(0x0100000C)
        )
        self.assertEqual(self.inspect(payload), ("Mach-O", {"x64", "arm64"}))

    def test_pe_x64_header(self) -> None:
        payload = bytearray(80)
        payload[:2] = b"MZ"
        payload[0x3C:0x40] = (64).to_bytes(4, "little")
        payload[64:68] = b"PE\0\0"
        payload[68:70] = (0x8664).to_bytes(2, "little")
        self.assertEqual(self.inspect(bytes(payload)), ("PE", {"x64"}))

    def test_elf_arm64_header(self) -> None:
        payload = bytearray(64)
        payload[:4] = b"\x7fELF"
        payload[5] = 1
        payload[18:20] = (183).to_bytes(2, "little")
        self.assertEqual(self.inspect(bytes(payload)), ("ELF", {"arm64"}))


if __name__ == "__main__":
    unittest.main()
