#!/usr/bin/env python3
"""Pure ELF-header fixtures for Android's ABI-specific LOAD-page policy."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("vision_runtime", Path(__file__).with_name("vision_runtime.py"))
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


def elf_fixture(machine, alignment, address=0):
    is64 = machine in (62, 183)
    data = bytearray(256)
    data[:7] = b"\x7fELF" + bytes((2 if is64 else 1, 1, 1))
    struct.pack_into("<HHI", data, 16, 3, machine, 1)
    struct.pack_into("<Q" if is64 else "<I", data, 32 if is64 else 28, 64)
    struct.pack_into("<HH", data, 54 if is64 else 42, 56 if is64 else 32, 1)
    if is64:
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 4, 0, address, address, 128, 128, alignment)
    else:
        struct.pack_into("<IIIIIIII", data, 64, 1, 0, address, address, 128, 128, 4, alignment)
    return data


class AndroidPageAlignment(unittest.TestCase):
    def gate(self, abi, alignment, address=0):
        machine = producer.ABIS[abi][1]
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / "libfixture.so"
            native.write_bytes(elf_fixture(machine, alignment, address))
            return producer.elf_gate(native, machine, producer.android_page_alignment(abi))

    def test_supported_ABIs_accept_their_actual_minimum(self):
        for abi, pages in (("armeabi-v7a", 4096), ("x86", 4096), ("arm64-v8a", 16384), ("x86_64", 16384)):
            with self.subTest(abi=abi):
                proof = self.gate(abi, pages)
                self.assertEqual(proof["required_page_bytes"], pages)
                self.assertEqual(proof["class"], 64 if pages == 16384 else 32)

    def test_32_bit_smaller_alignment_is_rejected_with_accurate_message(self):
        for abi in ("armeabi-v7a", "x86"):
            with self.subTest(abi=abi), self.assertRaisesRegex(RuntimeError, "4096-byte pages"):
                self.gate(abi, 2048)

    def test_64_bit_4KiB_is_still_rejected_with_accurate_message(self):
        for abi in ("arm64-v8a", "x86_64"):
            with self.subTest(abi=abi), self.assertRaisesRegex(RuntimeError, "16384-byte pages"):
                self.gate(abi, 4096)

    def test_larger_power_of_two_alignment_is_accepted(self):
        for abi in producer.ABIS:
            with self.subTest(abi=abi):
                self.assertEqual(self.gate(abi, 32768)["LOAD"][0]["alignment"], 32768)

    def test_non_power_of_two_alignment_remains_rejected(self):
        for abi in producer.ABIS:
            with self.subTest(abi=abi), self.assertRaises(RuntimeError):
                self.gate(abi, producer.android_page_alignment(abi) * 3)

    def test_LOAD_offset_address_congruence_remains_ABI_specific(self):
        for abi in ("armeabi-v7a", "x86"):
            with self.subTest(abi=abi):
                self.gate(abi, 4096, address=4096)
        for abi in ("arm64-v8a", "x86_64"):
            with self.subTest(abi=abi), self.assertRaises(RuntimeError):
                self.gate(abi, 16384, address=4096)
        for abi in producer.ABIS:
            with self.subTest(abi=abi), self.assertRaises(RuntimeError):
                self.gate(abi, producer.android_page_alignment(abi), address=1)

    def test_unknown_ABI_cannot_select_a_weaker_policy(self):
        for abi in ("mips", "arm", "arm64", "", None):
            with self.subTest(abi=abi), self.assertRaises(RuntimeError):
                producer.android_page_alignment(abi)


if __name__ == "__main__":
    unittest.main(verbosity=2)
