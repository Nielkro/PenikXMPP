#!/usr/bin/env python3
"""Embed and verify DinoX's UTF-8 process manifest in a Windows PE file."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET


ACTIVE_CODE_PAGE_NAMESPACE = (
    "http://schemas.microsoft.com/SMI/2019/WindowsSettings"
)
ACTIVE_CODE_PAGE_MARKER = (
    b'<activeCodePage xmlns="'
    + ACTIVE_CODE_PAGE_NAMESPACE.encode("ascii")
    + b'">UTF-8</activeCodePage>'
)
RT_MANIFEST = 24
CREATEPROCESS_MANIFEST_RESOURCE_ID = 1
LOAD_LIBRARY_AS_DATAFILE = 0x00000002
LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x00000020
IMAGE_DIRECTORY_ENTRY_SECURITY = 4
IMAGE_DIRECTORY_ENTRY_DEBUG = 6
IMAGE_SIZEOF_SYMBOL = 18
IMAGE_SIZEOF_SECTION_HEADER = 40
IMAGE_SIZEOF_DEBUG_DIRECTORY = 28


class ManifestError(RuntimeError):
    pass


class PeLayout:
    def __init__(
        self,
        *,
        coff_header_offset: int,
        optional_header_offset: int,
        optional_header_size: int,
        sections: list[tuple[int, int, int, int]],
        overlay_offset: int,
        symbol_table_offset: int,
        symbol_count: int,
        debug_directory_rva: int,
        debug_directory_size: int,
        security_directory_offset: int,
        security_directory_size: int,
    ) -> None:
        self.coff_header_offset = coff_header_offset
        self.optional_header_offset = optional_header_offset
        self.optional_header_size = optional_header_size
        self.sections = sections
        self.overlay_offset = overlay_offset
        self.symbol_table_offset = symbol_table_offset
        self.symbol_count = symbol_count
        self.debug_directory_rva = debug_directory_rva
        self.debug_directory_size = debug_directory_size
        self.security_directory_offset = security_directory_offset
        self.security_directory_size = security_directory_size


def unpack_u16(image: bytes | bytearray, offset: int, description: str) -> int:
    if offset < 0 or offset + 2 > len(image):
        raise ManifestError(f"truncated PE while reading {description}")
    return struct.unpack_from("<H", image, offset)[0]


def unpack_u32(image: bytes | bytearray, offset: int, description: str) -> int:
    if offset < 0 or offset + 4 > len(image):
        raise ManifestError(f"truncated PE while reading {description}")
    return struct.unpack_from("<I", image, offset)[0]


def inspect_pe_layout(
    image: bytes | bytearray, *, validate_symbol_table: bool
) -> PeLayout:
    if len(image) < 0x40 or image[:2] != b"MZ":
        raise ManifestError("input is not a DOS/PE executable")
    pe_offset = unpack_u32(image, 0x3C, "PE header offset")
    if pe_offset + 24 > len(image) or image[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ManifestError("input has no valid PE signature")

    coff_header_offset = pe_offset + 4
    section_count = unpack_u16(
        image, coff_header_offset + 2, "PE section count"
    )
    symbol_table_offset = unpack_u32(
        image, coff_header_offset + 8, "COFF symbol table offset"
    )
    symbol_count = unpack_u32(image, coff_header_offset + 12, "COFF symbol count")
    optional_header_size = unpack_u16(
        image, coff_header_offset + 16, "optional header size"
    )
    optional_header_offset = coff_header_offset + 20
    section_table_offset = optional_header_offset + optional_header_size
    section_table_end = (
        section_table_offset + section_count * IMAGE_SIZEOF_SECTION_HEADER
    )
    if section_count == 0 or section_table_end > len(image):
        raise ManifestError("input has a truncated or empty PE section table")

    sections: list[tuple[int, int, int, int]] = []
    overlay_offset = section_table_end
    for index in range(section_count):
        section_offset = section_table_offset + index * IMAGE_SIZEOF_SECTION_HEADER
        virtual_size = unpack_u32(
            image, section_offset + 8, f"section {index} virtual size"
        )
        virtual_address = unpack_u32(
            image, section_offset + 12, f"section {index} virtual address"
        )
        raw_size = unpack_u32(image, section_offset + 16, f"section {index} raw size")
        raw_offset = unpack_u32(
            image, section_offset + 20, f"section {index} raw offset"
        )
        if raw_size:
            raw_end = raw_offset + raw_size
            if raw_offset == 0 or raw_end > len(image):
                raise ManifestError(f"section {index} lies outside the PE file")
            overlay_offset = max(overlay_offset, raw_end)
        sections.append((virtual_address, virtual_size, raw_offset, raw_size))

    optional_magic = unpack_u16(image, optional_header_offset, "optional header magic")
    if optional_magic == 0x20B:
        data_directory_offset = optional_header_offset + 112
        directory_count_offset = optional_header_offset + 108
    elif optional_magic == 0x10B:
        data_directory_offset = optional_header_offset + 96
        directory_count_offset = optional_header_offset + 92
    else:
        raise ManifestError(f"unsupported PE optional header magic 0x{optional_magic:04x}")
    directory_count = unpack_u32(image, directory_count_offset, "data-directory count")

    def directory(index: int) -> tuple[int, int]:
        if directory_count <= index:
            return (0, 0)
        entry_offset = data_directory_offset + index * 8
        if entry_offset + 8 > optional_header_offset + optional_header_size:
            raise ManifestError("PE data-directory table exceeds the optional header")
        return (
            unpack_u32(image, entry_offset, f"data directory {index} address"),
            unpack_u32(image, entry_offset + 4, f"data directory {index} size"),
        )

    security_directory_offset, security_directory_size = directory(
        IMAGE_DIRECTORY_ENTRY_SECURITY
    )
    debug_directory_rva, debug_directory_size = directory(IMAGE_DIRECTORY_ENTRY_DEBUG)

    if bool(symbol_table_offset) != bool(symbol_count):
        raise ManifestError("inconsistent COFF symbol table pointer/count")
    if validate_symbol_table and symbol_table_offset:
        if symbol_table_offset < overlay_offset:
            raise ManifestError("COFF symbol table is not in the PE overlay")
        symbol_table_end = symbol_table_offset + symbol_count * IMAGE_SIZEOF_SYMBOL
        if symbol_table_end + 4 > len(image):
            raise ManifestError("COFF symbol table lies outside the PE file")
        string_table_size = unpack_u32(
            image, symbol_table_end, "COFF string-table size"
        )
        if string_table_size < 4 or symbol_table_end + string_table_size > len(image):
            raise ManifestError("COFF string table lies outside the PE file")

    return PeLayout(
        coff_header_offset=coff_header_offset,
        optional_header_offset=optional_header_offset,
        optional_header_size=optional_header_size,
        sections=sections,
        overlay_offset=overlay_offset,
        symbol_table_offset=symbol_table_offset,
        symbol_count=symbol_count,
        debug_directory_rva=debug_directory_rva,
        debug_directory_size=debug_directory_size,
        security_directory_offset=security_directory_offset,
        security_directory_size=security_directory_size,
    )


def rva_to_file_offset(layout: PeLayout, rva: int, size: int) -> int:
    for virtual_address, virtual_size, raw_offset, raw_size in layout.sections:
        mapped_size = max(virtual_size, raw_size)
        if virtual_address <= rva and rva + size <= virtual_address + mapped_size:
            offset = raw_offset + (rva - virtual_address)
            if offset + size <= raw_offset + raw_size:
                return offset
    raise ManifestError("PE data-directory RVA is not backed by section data")


def require_no_overlay_debug_data(image: bytes, layout: PeLayout) -> None:
    if not layout.debug_directory_rva or not layout.debug_directory_size:
        return
    if layout.debug_directory_size % IMAGE_SIZEOF_DEBUG_DIRECTORY:
        raise ManifestError("PE debug directory has an invalid size")
    directory_offset = rva_to_file_offset(
        layout, layout.debug_directory_rva, layout.debug_directory_size
    )
    for offset in range(
        directory_offset,
        directory_offset + layout.debug_directory_size,
        IMAGE_SIZEOF_DEBUG_DIRECTORY,
    ):
        data_size = unpack_u32(image, offset + 16, "debug-data size")
        data_offset = unpack_u32(image, offset + 24, "debug-data file offset")
        if data_size and data_offset >= layout.overlay_offset:
            raise ManifestError(
                "refusing to rewrite a PE with debug data stored in its overlay"
            )


def restore_pe_overlay(
    executable: Path, original_image: bytes, original_layout: PeLayout
) -> None:
    updated_image = bytearray(executable.read_bytes())
    updated_layout = inspect_pe_layout(updated_image, validate_symbol_table=False)
    if updated_layout.security_directory_offset or updated_layout.security_directory_size:
        raise ManifestError("resource update unexpectedly added a PE security directory")
    if len(updated_image) < updated_layout.overlay_offset:
        raise ManifestError("resource update produced a truncated PE image")

    overlay = original_image[original_layout.overlay_offset :]
    del updated_image[updated_layout.overlay_offset :]
    updated_image.extend(overlay)

    if original_layout.symbol_table_offset:
        symbol_offset_in_overlay = (
            original_layout.symbol_table_offset - original_layout.overlay_offset
        )
        updated_symbol_table_offset = (
            updated_layout.overlay_offset + symbol_offset_in_overlay
        )
        struct.pack_into(
            "<I",
            updated_image,
            updated_layout.coff_header_offset + 8,
            updated_symbol_table_offset,
        )
    else:
        struct.pack_into("<I", updated_image, updated_layout.coff_header_offset + 8, 0)
    struct.pack_into(
        "<I",
        updated_image,
        updated_layout.coff_header_offset + 12,
        original_layout.symbol_count,
    )

    inspect_pe_layout(updated_image, validate_symbol_table=True)
    executable.write_bytes(updated_image)


def validate_manifest(manifest_path: Path) -> bytes:
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise ManifestError(f"manifest is missing or not a regular file: {manifest_path}")
    manifest = manifest_path.read_bytes()
    if ACTIVE_CODE_PAGE_MARKER not in manifest:
        raise ManifestError("manifest does not select the UTF-8 active code page")
    try:
        root = ET.fromstring(manifest)
    except ET.ParseError as error:
        raise ManifestError(f"manifest is not valid XML: {error}") from error
    active_code_page = root.find(
        ".//{%s}activeCodePage" % ACTIVE_CODE_PAGE_NAMESPACE
    )
    if active_code_page is None or (active_code_page.text or "").strip() != "UTF-8":
        raise ManifestError("manifest has no valid UTF-8 activeCodePage element")
    return manifest


def verify_embedded_manifest(executable: Path) -> None:
    if not executable.is_file() or executable.is_symlink():
        raise ManifestError(
            f"Windows executable is missing or not a regular file: {executable}"
        )
    if ACTIVE_CODE_PAGE_MARKER not in executable.read_bytes():
        raise ManifestError(
            f"Windows executable has no embedded UTF-8 process manifest: {executable}"
        )


def integer_resource(identifier: int) -> wintypes.LPWSTR:
    return ctypes.cast(ctypes.c_void_p(identifier), wintypes.LPWSTR)


def require_neutral_manifest(executable: Path) -> None:
    """Require the pinned Tor RT_MANIFEST/1/LANG_NEUTRAL resource."""
    if os.name != "nt":
        raise ManifestError("reading Windows PE resources requires Windows")

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    load_library = kernel32.LoadLibraryExW
    load_library.argtypes = (wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD)
    load_library.restype = wintypes.HMODULE
    free_library = kernel32.FreeLibrary
    free_library.argtypes = (wintypes.HMODULE,)
    free_library.restype = wintypes.BOOL
    find_resource = kernel32.FindResourceExW
    find_resource.argtypes = (
        wintypes.HMODULE,
        wintypes.LPWSTR,
        wintypes.LPWSTR,
        wintypes.WORD,
    )
    find_resource.restype = wintypes.HANDLE

    module = load_library(
        str(executable),
        None,
        LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE,
    )
    if not module:
        raise ManifestError(
            f"LoadLibraryExW failed: {ctypes.WinError(ctypes.get_last_error())}"
        )

    try:
        resource = find_resource(
            module,
            integer_resource(RT_MANIFEST),
            integer_resource(CREATEPROCESS_MANIFEST_RESOURCE_ID),
            0,
        )
        if not resource:
            raise ManifestError(
                "the pinned executable has no RT_MANIFEST/1/LANG_NEUTRAL resource: "
                f"{ctypes.WinError(ctypes.get_last_error())}"
            )
    finally:
        free_library(module)


def update_manifest_resource(executable: Path, manifest: bytes) -> None:
    if os.name != "nt":
        raise ManifestError("embedding a Windows PE manifest requires Windows")

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    begin_update = kernel32.BeginUpdateResourceW
    begin_update.argtypes = (wintypes.LPCWSTR, wintypes.BOOL)
    begin_update.restype = wintypes.HANDLE
    update_resource = kernel32.UpdateResourceW
    update_resource.argtypes = (
        wintypes.HANDLE,
        wintypes.LPWSTR,
        wintypes.LPWSTR,
        wintypes.WORD,
        wintypes.LPVOID,
        wintypes.DWORD,
    )
    update_resource.restype = wintypes.BOOL
    end_update = kernel32.EndUpdateResourceW
    end_update.argtypes = (wintypes.HANDLE, wintypes.BOOL)
    end_update.restype = wintypes.BOOL

    require_neutral_manifest(executable)
    handle = begin_update(str(executable), False)
    if not handle:
        raise ManifestError(
            f"BeginUpdateResourceW failed: {ctypes.WinError(ctypes.get_last_error())}"
        )

    buffer = ctypes.create_string_buffer(manifest)
    if not update_resource(
        handle,
        integer_resource(RT_MANIFEST),
        integer_resource(CREATEPROCESS_MANIFEST_RESOURCE_ID),
        0,
        ctypes.cast(buffer, wintypes.LPVOID),
        len(manifest),
    ):
        error = ctypes.WinError(ctypes.get_last_error())
        end_update(handle, True)
        raise ManifestError(f"UpdateResourceW failed: {error}")
    if not end_update(handle, False):
        raise ManifestError(
            f"EndUpdateResourceW failed: {ctypes.WinError(ctypes.get_last_error())}"
        )


def embed_manifest(executable: Path, manifest_path: Path) -> None:
    manifest = validate_manifest(manifest_path)
    if not executable.is_file() or executable.is_symlink():
        raise ManifestError(
            f"Windows executable is missing or not a regular file: {executable}"
        )

    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=f".{executable.name}.manifest-",
            suffix=".tmp",
            dir=executable.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
        shutil.copy2(executable, temporary_path)
        original_image = temporary_path.read_bytes()
        original_layout = inspect_pe_layout(
            original_image, validate_symbol_table=True
        )
        if (
            original_layout.security_directory_offset
            or original_layout.security_directory_size
        ):
            raise ManifestError(
                "refusing to invalidate an Authenticode-signed PE executable"
            )
        require_no_overlay_debug_data(original_image, original_layout)
        update_manifest_resource(temporary_path, manifest)
        restore_pe_overlay(temporary_path, original_image, original_layout)
        verify_embedded_manifest(temporary_path)
        os.replace(temporary_path, executable)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="dinox-manifest-self-test-") as root_text:
        root = Path(root_text)
        good = root / "good.manifest"
        bad = root / "bad.manifest"
        good.write_bytes(
            b'<?xml version="1.0"?><assembly xmlns="urn:schemas-microsoft-com:asm.v1">'
            b'<application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>'
            + ACTIVE_CODE_PAGE_MARKER
            + b"</windowsSettings></application></assembly>"
        )
        bad.write_text(
            '<?xml version="1.0"?><assembly '
            'xmlns="urn:schemas-microsoft-com:asm.v1"/>',
            encoding="utf-8",
        )
        validate_manifest(good)
        try:
            validate_manifest(bad)
        except ManifestError:
            pass
        else:
            raise ManifestError("self-test accepted a manifest without UTF-8 code page")

        pe_offset = 0x80
        coff_header_offset = pe_offset + 4
        optional_header_offset = coff_header_offset + 20
        optional_header_size = 240
        section_header_offset = optional_header_offset + optional_header_size
        original_overlay_offset = 0x400
        updated_overlay_offset = 0x600
        symbol_tail = b"\0" * IMAGE_SIZEOF_SYMBOL + struct.pack("<I", 4)

        def synthetic_pe(overlay_offset: int, include_symbol_tail: bool) -> bytes:
            image = bytearray(overlay_offset)
            image[:2] = b"MZ"
            struct.pack_into("<I", image, 0x3C, pe_offset)
            image[pe_offset : pe_offset + 4] = b"PE\0\0"
            struct.pack_into(
                "<HHIIIHH",
                image,
                coff_header_offset,
                0x8664,
                1,
                0,
                original_overlay_offset,
                1,
                optional_header_size,
                0x22,
            )
            struct.pack_into("<H", image, optional_header_offset, 0x20B)
            struct.pack_into("<I", image, optional_header_offset + 108, 16)
            image[section_header_offset : section_header_offset + 8] = b".rsrc\0\0\0"
            raw_size = overlay_offset - 0x200
            struct.pack_into("<I", image, section_header_offset + 8, raw_size)
            struct.pack_into("<I", image, section_header_offset + 12, 0x1000)
            struct.pack_into("<I", image, section_header_offset + 16, raw_size)
            struct.pack_into("<I", image, section_header_offset + 20, 0x200)
            if include_symbol_tail:
                image.extend(symbol_tail)
            return bytes(image)

        original_image = synthetic_pe(original_overlay_offset, True)
        original_layout = inspect_pe_layout(
            original_image, validate_symbol_table=True
        )
        transformed = root / "transformed.exe"
        transformed.write_bytes(synthetic_pe(updated_overlay_offset, False))
        restore_pe_overlay(transformed, original_image, original_layout)
        transformed_image = transformed.read_bytes()
        transformed_layout = inspect_pe_layout(
            transformed_image, validate_symbol_table=True
        )
        if transformed_layout.symbol_table_offset != updated_overlay_offset:
            raise ManifestError("self-test did not relocate the COFF symbol table")
        if transformed_image[updated_overlay_offset:] != symbol_tail:
            raise ManifestError("self-test did not preserve the COFF symbol/string table")
    print("Self-test OK")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Embed or verify a UTF-8 process manifest in a Windows PE file."
    )
    subparsers = result.add_subparsers(dest="command", required=True)
    embed_parser = subparsers.add_parser("embed")
    embed_parser.add_argument("executable", type=Path)
    embed_parser.add_argument("manifest", type=Path)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("executable", type=Path)
    subparsers.add_parser("self-test")
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "embed":
            embed_manifest(arguments.executable, arguments.manifest)
            print(f"OK: embedded UTF-8 process manifest in {arguments.executable}")
        elif arguments.command == "check":
            verify_embedded_manifest(arguments.executable)
            print(f"OK: UTF-8 process manifest present in {arguments.executable}")
        else:
            run_self_test()
    except (ManifestError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
