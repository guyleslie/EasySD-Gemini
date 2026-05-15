#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
EasySD - Unified Professional Build System

Supports C64 and Arduino builds from a single command-line interface.

Usage Examples:
  # C64 builds
  python build.py release              # Full release bundles (release/upload/sd-content)
  python build.py sd-content           # Rebuild SD content bundle from current artifacts

  # Arduino operations
  python build.py arduino-setup        # One-time Arduino-CLI setup
  python build.py arduino-compile      # Compile Arduino (release mode)
  python build.py arduino-compile --debug  # Compile Arduino (debug mode - SERIAL ON)
  python build.py arduino-upload-isp   # Upload via ISP (USBtinyISP)
  python build.py arduino-upload-isp --debug  # Upload Arduino debug firmware (SERIAL ON)
  python build.py arduino-monitor COM4 # Serial monitor (57600 baud)
  python build.py arduino-clean        # Clean Arduino temp files

Author: Claude Sonnet 4.5 (POST-SPRINT6)
Version: 3.0.0
Date: 2025-12-26
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

# Fix Windows console encoding (CP1252 → UTF-8) so Hungarian chars display correctly
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


# ============================================================================
# Platform & Utilities
# ============================================================================

def is_windows() -> bool:
    return os.name == "nt"


def find_repo_root(start: Path) -> Path:
    """
    Find repo root by locating sibling directories: Tools + Arduino + EasySD.
    """
    p = start.resolve()
    for candidate in [p, *p.parents]:
        if (candidate / "Tools").is_dir() and (candidate / "Arduino").is_dir() and (candidate / "EasySD").is_dir():
            return candidate
    raise SystemExit(
        "ERROR: Could not locate repo root. Expected directories: Tools/, Arduino/, EasySD/.\n"
        "Run from inside the repo."
    )


# ============================================================================
# Context
# ============================================================================

@dataclass(frozen=True)
class Context:
    repo_root: Path
    irq_root: Path         # <repo_root>/EasySD
    arduino_root: Path     # <repo_root>/Arduino/EasySD
    tools_dir: Path        # <repo_root>/Tools
    build_dir: Path        # <irq_root>/build
    sym_dir: Path
    lst_dir: Path
    plugins_out_dir: Path


def make_context() -> Context:
    here = Path(__file__).resolve()
    repo_root = find_repo_root(here.parent)
    irq_root = repo_root / "EasySD"
    arduino_root = repo_root / "Arduino" / "EasySD"
    tools_dir = repo_root / "Tools"
    build_dir = irq_root / "build"
    return Context(
        repo_root=repo_root,
        irq_root=irq_root,
        arduino_root=arduino_root,
        tools_dir=tools_dir,
        build_dir=build_dir,
        sym_dir=build_dir / "symbol",
        lst_dir=build_dir / "listing",
        plugins_out_dir=build_dir / "plugins",
    )


# ============================================================================
# Tool Resolution
# ============================================================================

def resolve_tool(ctx: Context, names: Sequence[str]) -> Path:
    """
    Find a tool either on PATH or in repo Tools dir, return absolute path.
    """
    for name in names:
        hit = shutil.which(name)
        if hit:
            return Path(hit).resolve()

    for name in names:
        p = ctx.tools_dir / name
        if p.exists():
            return p.resolve()
        if is_windows() and not name.lower().endswith(".exe"):
            p2 = ctx.tools_dir / f"{name}.exe"
            if p2.exists():
                return p2.resolve()

    raise SystemExit(
        f"ERROR: Missing tool: one of {list(names)}.\n"
        f"Put it on PATH or copy it into: {ctx.tools_dir}"
    )


def find_arduino_cli(ctx: Context) -> Path:
    """Find arduino-cli executable"""
    candidates = [
        ctx.tools_dir / "arduino-cli.exe",
        Path("C:/Program Files/Arduino CLI/arduino-cli.exe"),
        Path("C:/Program Files (x86)/Arduino CLI/arduino-cli.exe"),
    ]

    for cli_exe in candidates:
        if cli_exe.exists():
            return cli_exe

    # Check in PATH
    cli_path = shutil.which("arduino-cli")
    if cli_path:
        return Path(cli_path)

    print("\nERROR: arduino-cli not found!")
    print("\nSearched locations:")
    for loc in candidates:
        print(f"  - {loc}")
    print("\nDownload from: https://arduino.github.io/arduino-cli/latest/installation/")
    print("Or install via: winget install Arduino.ArduinoCLI")
    print("\nThen run: python build.py arduino-setup")
    sys.exit(1)


# ============================================================================
# Command Execution
# ============================================================================

def run_cmd(cmd: Sequence[str | os.PathLike], cwd: Path) -> None:
    cmd_str = " ".join(str(c) for c in cmd)
    print(f"[RUN] {cmd_str}")
    p = subprocess.run([str(c) for c in cmd], cwd=str(cwd))
    if p.returncode != 0:
        print(f"ERROR: Command failed with exit code {p.returncode}")
        raise SystemExit(p.returncode)


def run_arduino_cli(cli_exe: Path, args: list, check=True) -> subprocess.CompletedProcess:
    """Run arduino-cli command, capturing output for size parsing while printing in real-time"""
    cmd = [str(cli_exe)] + args
    print(f"\n> {' '.join(cmd)}")
    lines = []
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace")
    for line in process.stdout:
        print(line, end="", flush=True)
        lines.append(line)
    process.wait()
    if check and process.returncode != 0:
        raise SystemExit(process.returncode)
    result = subprocess.CompletedProcess(cmd, process.returncode, stdout="".join(lines))
    return result


def parse_arduino_size(output: str) -> dict | None:
    """Extract flash and RAM usage from arduino-cli compile output"""
    fm = re.search(r"Sketch uses (\d+) bytes \((\d+)%\) of program storage space\. Maximum is (\d+) bytes\.", output)
    rm = re.search(r"Global variables use (\d+) bytes \((\d+)%\) of dynamic memory, leaving (\d+) bytes", output)
    if fm and rm:
        return {
            "flash_used": int(fm.group(1)), "flash_pct": int(fm.group(2)), "flash_max": int(fm.group(3)),
            "ram_used": int(rm.group(1)),   "ram_pct":   int(rm.group(2)), "ram_free":  int(rm.group(3)),
        }
    return None


def print_size_summary(size: dict) -> None:
    flash_free = size["flash_max"] - size["flash_used"]
    print("\n" + "="*70)
    print("BUILD SUMMARY")
    print("="*70)
    print(f"  Flash:  {size['flash_used']:>6} / {size['flash_max']} B   ({size['flash_pct']}% used, {flash_free} B free)")
    print(f"  RAM:    {size['ram_used']:>6} / 2048 B   ({size['ram_pct']}% used, {size['ram_free']} B free)")
    print("="*70)


# ============================================================================
# File Operations
# ============================================================================

def ensure_dirs(ctx: Context) -> None:
    ctx.build_dir.mkdir(exist_ok=True)
    ctx.sym_dir.mkdir(exist_ok=True)
    ctx.lst_dir.mkdir(exist_ok=True)
    ctx.plugins_out_dir.mkdir(exist_ok=True)


def reset_dir(path: Path) -> None:
    if path.exists():
        clear_hidden_tree(path)
        try:
            shutil.rmtree(path)
        except PermissionError:
            for root, dirs, files in os.walk(path, topdown=False):
                for f in files:
                    try:
                        os.remove(os.path.join(root, f))
                    except OSError:
                        pass
                for d in dirs:
                    try:
                        os.rmdir(os.path.join(root, d))
                    except OSError:
                        pass
    path.mkdir(parents=True, exist_ok=True)


def set_hidden_attr(path: Path, hidden: bool = True) -> None:
    """Set or clear the Windows hidden attribute. No-op on other platforms."""
    if not is_windows():
        return

    import ctypes

    file_attribute_hidden = 0x02
    invalid_file_attributes = 0xFFFFFFFF
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetFileAttributesW.argtypes = [ctypes.c_wchar_p]
    kernel32.GetFileAttributesW.restype = ctypes.c_uint32
    kernel32.SetFileAttributesW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32]
    kernel32.SetFileAttributesW.restype = ctypes.c_int

    path_str = str(path)
    attrs = kernel32.GetFileAttributesW(path_str)
    if attrs == invalid_file_attributes:
        raise ctypes.WinError(ctypes.get_last_error())

    new_attrs = (attrs | file_attribute_hidden) if hidden else (attrs & ~file_attribute_hidden)
    if new_attrs != attrs and not kernel32.SetFileAttributesW(path_str, new_attrs):
        raise ctypes.WinError(ctypes.get_last_error())


def clear_hidden_tree(path: Path) -> None:
    """Clear hidden bits before deleting or overwriting Windows build artifacts."""
    if not is_windows() or not path.exists():
        return

    try:
        set_hidden_attr(path, hidden=False)
    except OSError:
        pass

    if path.is_dir():
        for root, dirs, files in os.walk(path):
            for name in [*dirs, *files]:
                try:
                    set_hidden_attr(Path(root) / name, hidden=False)
                except OSError:
                    pass


def copyfile_for_bundle(src: Path, dst: Path, *, hidden: bool = False) -> None:
    """
    Copy a file and optionally mark the destination hidden.

    Windows refuses some overwrites when the existing destination is hidden,
    so clear only that bit first and restore the desired final state after copy.
    """
    if dst.exists():
        set_hidden_attr(dst, hidden=False)
    shutil.copyfile(src, dst)
    if hidden:
        set_hidden_attr(dst, hidden=True)


def mark_sd_system_items_hidden(sd_root: Path) -> None:
    """Hide the SD runtime files that should not appear in the EasySD menu."""
    menu = sd_root / "EASYSD.PRG"
    plugins_dir = sd_root / "PLUGINS"

    if menu.exists():
        set_hidden_attr(menu, hidden=True)

    if plugins_dir.exists():
        for plugin in plugins_dir.glob("*.PRG"):
            set_hidden_attr(plugin, hidden=True)
        set_hidden_attr(plugins_dir, hidden=True)


def default_arduino_compile_dir(ctx: Context) -> Path:
    return ctx.build_dir / "_arduino-compile"


def prepare_arduino_cli_paths(ctx: Context, profile: str) -> tuple[Path, Path]:
    """
    Use ASCII-only temp paths for Arduino CLI build output.
    AVR binutils may fail on non-ASCII working paths (e.g. "Asztali gép").
    """
    import tempfile
    temp_root = Path(tempfile.gettempdir()) / "easysd_arduino_cli"
    build_path = temp_root / profile
    reset_dir(build_path)
    return build_path, temp_root


def _resolve_menu_artifact(ctx: Context, preferred_menu_name: str) -> Path:
    preferred = ctx.build_dir / preferred_menu_name
    release_default = ctx.build_dir / "easysd.prg"
    if preferred.exists():
        return preferred
    if release_default.exists():
        return release_default
    raise SystemExit(
        "ERROR: Missing menu PRG artifact. Build core first.\n"
        "Expected: build/easysd.prg"
    )


def _collect_plugin_artifacts(ctx: Context) -> list[Path]:
    return sorted(ctx.plugins_out_dir.glob("*.prg"))


def stage_sd_content_bundle(ctx: Context, preferred_menu_name: str, dst_root: Path | None = None, clean: bool = True) -> Path:
    target_root = dst_root or (ctx.build_dir / "sd-content")
    if clean:
        reset_dir(target_root)
    else:
        target_root.mkdir(parents=True, exist_ok=True)

    plugins_dst = target_root / "PLUGINS"
    plugins_dst.mkdir(parents=True, exist_ok=True)

    menu_src = _resolve_menu_artifact(ctx, preferred_menu_name)
    menu_dst = target_root / "EASYSD.PRG"
    copyfile_for_bundle(menu_src, menu_dst, hidden=True)
    print(f"[STAGE:SD] {menu_src.name} -> {menu_dst}")

    plugin_files = _collect_plugin_artifacts(ctx)
    if not plugin_files:
        raise SystemExit("ERROR: No plugin PRG files found in build/plugins. Run a plugin build first.")

    for src in plugin_files:
        dst = plugins_dst / src.name.upper()
        copyfile_for_bundle(src, dst, hidden=True)
        print(f"[STAGE:SD] {src.name} -> {dst.name}")

    mark_sd_system_items_hidden(target_root)

    manifest = target_root / "manifest.txt"
    manifest.write_text(
        "\n".join(
            [
                "kind=sd-content",
                f"generated_utc={datetime.now(timezone.utc).isoformat()}",
                f"menu={menu_src.name}",
                f"plugin_count={len(plugin_files)}",
            ]
        ) + "\n",
        encoding="utf-8",
    )
    print(f"[STAGE:SD] Ready: {target_root}")
    return target_root


def read_manifest_value(manifest_path: Path, key: str) -> str | None:
    """Read a simple key=value manifest entry."""
    if not manifest_path.exists():
        return None
    try:
        for line in manifest_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith(f"{key}="):
                return line.split("=", 1)[1].strip()
    except OSError:
        return None
    return None


def stage_upload_bundle(ctx: Context, compile_dir: Path, mode_label: str) -> Path:
    upload_root = ctx.build_dir / "upload"
    reset_dir(upload_root)
    arduino_dst = upload_root / "arduino"
    arduino_dst.mkdir(parents=True, exist_ok=True)

    if not compile_dir.exists():
        raise SystemExit(f"ERROR: Arduino compile output directory not found: {compile_dir}")

    copied = 0
    for src in sorted(compile_dir.glob("EasySD.ino.*")):
        if src.is_file():
            shutil.copyfile(src, arduino_dst / src.name)
            copied += 1

    if copied == 0:
        raise SystemExit(
            f"ERROR: No Arduino output files found in {compile_dir}.\n"
            "Expected files like EasySD.ino.hex / .elf / .eep"
        )

    buildconfig_h = ctx.arduino_root / "BuildConfig.h"
    if buildconfig_h.exists():
        shutil.copyfile(buildconfig_h, upload_root / "BuildConfig.h")

    flashlib_h = ctx.arduino_root / "FlashLib.h"
    if flashlib_h.exists():
        shutil.copyfile(flashlib_h, upload_root / "FlashLib.h")

    manifest = upload_root / "manifest.txt"
    manifest.write_text(
        "\n".join(
            [
                "kind=upload",
                f"generated_utc={datetime.now(timezone.utc).isoformat()}",
                f"mode={mode_label}",
                f"source_dir={compile_dir}",
                f"arduino_file_count={copied}",
            ]
        ) + "\n",
        encoding="utf-8",
    )
    print(f"[STAGE:UPLOAD] Ready: {upload_root}")
    return upload_root


def stage_release_bundle(ctx: Context, preferred_menu_name: str, mode_label: str, include_upload: bool = True) -> Path:
    release_root = ctx.build_dir / "release"
    reset_dir(release_root)

    c64_dir = release_root / "c64"
    plugins_dir = release_root / "plugins"
    arduino_dir = release_root / "arduino"
    symbol_dir = release_root / "symbol"
    listing_dir = release_root / "listing"
    for d in (c64_dir, plugins_dir, arduino_dir, symbol_dir, listing_dir):
        d.mkdir(parents=True, exist_ok=True)

    menu_src = _resolve_menu_artifact(ctx, preferred_menu_name)
    shutil.copyfile(menu_src, c64_dir / menu_src.name)

    core_optional = ["warning.prg", "IRQLoaderRom.bin", "FlashLib.h", "defaultmenu.h", "LoaderStub.h"]
    for name in core_optional:
        src = ctx.build_dir / name
        if src.exists():
            shutil.copyfile(src, c64_dir / src.name)

    plugin_files = _collect_plugin_artifacts(ctx)
    if not plugin_files:
        raise SystemExit("ERROR: No plugin PRG files found in build/plugins. Cannot package release.")
    for src in plugin_files:
        shutil.copyfile(src, plugins_dir / src.name)

    for src in sorted(ctx.sym_dir.glob("*")):
        if src.is_file():
            shutil.copyfile(src, symbol_dir / src.name)
    for src in sorted(ctx.lst_dir.glob("*")):
        if src.is_file():
            shutil.copyfile(src, listing_dir / src.name)

    upload_root = ctx.build_dir / "upload"
    if include_upload and upload_root.exists():
        for src in sorted(upload_root.rglob("*")):
            if src.is_file():
                rel = src.relative_to(upload_root)
                dst = arduino_dir / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)

    stage_sd_content_bundle(ctx, preferred_menu_name, dst_root=release_root / "sd-content", clean=False)

    manifest = release_root / "manifest.txt"
    manifest.write_text(
        "\n".join(
            [
                "kind=release",
                f"generated_utc={datetime.now(timezone.utc).isoformat()}",
                f"mode={mode_label}",
                f"menu={menu_src.name}",
                f"plugin_count={len(plugin_files)}",
            ]
        ) + "\n",
        encoding="utf-8",
    )
    print(f"[STAGE:RELEASE] Ready: {release_root}")
    return release_root


def convert_petmate_asm(src: Path, dst: Path) -> None:
    """Convert PETMATE .asm export (!byte directives) to raw binary."""
    data = []
    with src.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("!byte"):
                nums_str = stripped[5:].strip()
                for val in nums_str.split(","):
                    val = val.strip()
                    if val:
                        data.append(int(val))
    dst.write_bytes(bytes(data))
    print(f"[CORE] PETMATE: {src.name} -> {dst.name} ({len(data)} bytes)")


def bin2ardh(input_file: Path, output_file: Path, size_decl: str, var_decl: str) -> None:
    """Python implementation of Bin2ArdH.cs"""
    print(f"[BIN2ARDH] {input_file.name} -> {output_file.name}")
    data = input_file.read_bytes()
    header = f"int {size_decl} = {len(data)};\r\nstatic const unsigned char PROGMEM {var_decl}[{len(data)}]="

    with output_file.open("w", encoding="ascii") as f:
        f.write(header)
        f.write("\r\n{\r\n")
        for i in range(0, len(data), 16):
            chunk = data[i:i+16]
            hex_vals = []
            for j, b in enumerate(chunk):
                is_last = (i + j) == (len(data) - 1)
                hex_vals.append(f"0x{b:02X}" + ("" if is_last else ","))
            f.write("".join(hex_vals) + "\n")
        f.write("\r\n};")


def create_eprom_loader(input_file: Path, output_file: Path, positions: list[int]) -> None:
    """Python implementation of CreateEpromLoader.cs"""
    print(f"[EPROM] {input_file.name} -> {output_file.name}")
    data = bytearray(input_file.read_bytes())
    if len(data) != 256:
        print(f"WARNING: Input file size is {len(data)}, expected 256.")

    eprom_data = bytearray(65536)
    for i in range(256):
        page = bytearray(data)
        for pos in positions:
            if pos < len(page):
                page[pos] = i
        eprom_data[i*256 : (i+1)*256] = page[:256]

    output_file.write_bytes(eprom_data)


def parse_64tass_int(value: str) -> int:
    value = value.strip()
    if value.startswith("$"):
        return int(value[1:], 16)
    return int(value, 0)


def read_64tass_labels(label_file: Path) -> dict[str, int]:
    if not label_file.exists():
        raise SystemExit(f"ERROR: Missing labels file: {label_file}")

    symbols: dict[str, int] = {}
    pattern = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^\s;]+)")
    for line in label_file.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = pattern.match(line.strip())
        if m:
            symbols[m.group(1)] = parse_64tass_int(m.group(2))
    return symbols


def read_irq_loader_placeholder_positions(label_file: Path) -> list[int]:
    """
    Read IRQLoader PLACEHOLDER offsets from the 64tass labels file.

    IRQLoader.65s marks every byte that must be patched with the selected
    ROM page value when expanding the 256-byte template into IRQLoaderRom.bin.
    Keeping this derived from labels prevents stale EPROM patch offsets after
    small loader layout changes.
    """
    symbols = read_64tass_labels(label_file)

    names = [f"PLACEHOLDER{i}" for i in range(1, 13)]
    missing = [name for name in names if name not in symbols]
    if missing:
        raise SystemExit(
            f"ERROR: Missing IRQLoader placeholder symbols in {label_file}: {', '.join(missing)}"
        )

    positions = [symbols[name] for name in names]
    invalid = [pos for pos in positions if pos < 0 or pos > 255]
    if invalid:
        raise SystemExit(
            f"ERROR: IRQLoader placeholder offsets must be in 0..255: {invalid}"
        )

    return positions


def validate_cvd_memory_layout(label_file: Path) -> None:
    symbols = read_64tass_labels(label_file)

    expected = {
        "PICTURE_LO": 0x2000,
        "VIDEO_B0": 0x2000,
        "PICTURE_HI": 0x6000,
        "VIDEO_B1": 0x6000,
        "COLORBUFFER": 0x4000,
        "SCREEN_HI": 0x4400,
        "CVD_COLORCOPY_START": 0x4800,
        "TRANSFERBUFFER": 0xA000,
        "FILEINFOBUFFER": 0xA000,
    }
    missing_expected = [name for name in expected if name not in symbols]
    if missing_expected:
        raise SystemExit(
            f"ERROR: CVD layout guard missing symbols in {label_file}: {', '.join(missing_expected)}"
        )

    wrong = [
        f"{name}=${symbols[name]:04X} expected ${addr:04X}"
        for name, addr in expected.items()
        if symbols[name] != addr
    ]
    if wrong:
        raise SystemExit("ERROR: CVD fixed memory layout changed: " + "; ".join(wrong))

    critical = [
        "INIT", "ENABLEDISPLAY", "INIT_GFX_MEM", "SET_LO_COLOR", "SET_HI_COLOR",
        "SETMULTICOLOR", "COPYCOLOR", "MEDIAPATH_BUF", "ENDOFEXECUTABLE",
        "CVD_LOW_CODE_END", "CVD_HELPER_END", "SIMPLEHANDLER", "WAITFRAMES",
        "PREPAREJMPTAB", "OUTCOPY", "ERROR_OPENING_FILE", "CVD_DONE",
        "NMI_000", "PROT_StartTalking", "PROT_EndTalking", "PROT_SetNameZ",
        "PROT_OpenFile", "PROT_CloseFile", "PROT_GetInfoForFile",
        "PROT_NIStream", "PROT_ExitToMenu",
    ]
    missing_critical = [name for name in critical if name not in symbols]
    if missing_critical:
        raise SystemExit(
            f"ERROR: CVD layout guard missing critical symbols in {label_file}: {', '.join(missing_critical)}"
        )

    layout_markers = ["CVD_COLORCOPY_END"]
    missing_markers = [name for name in layout_markers if name not in symbols]
    if missing_markers:
        raise SystemExit(
            f"ERROR: CVD layout guard missing segment markers in {label_file}: {', '.join(missing_markers)}"
        )

    forbidden_ranges = [
        (0x2000, 0x3FFF, "bitmap buffer 0"),
        (0x6000, 0x7FFF, "bitmap buffer 1"),
    ]
    violations: list[str] = []
    for name in critical:
        addr = symbols[name]
        for start, end, label in forbidden_ranges:
            if start <= addr <= end:
                violations.append(f"{name}=${addr:04X} in {label}")

    if symbols["CVD_LOW_CODE_END"] > 0x2000:
        violations.append(f"CVD_LOW_CODE_END=${symbols['CVD_LOW_CODE_END']:04X} exceeds $2000")
    if symbols["CVD_HELPER_END"] > 0xD000:
        violations.append(f"CVD_HELPER_END=${symbols['CVD_HELPER_END']:04X} exceeds $C000-$CFFF")
    if not (0x4800 <= symbols["COPYCOLOR"] < 0x6000):
        violations.append(f"COPYCOLOR=${symbols['COPYCOLOR']:04X} outside $4800-$5FFF")
    if symbols["CVD_COLORCOPY_END"] > 0x6000:
        violations.append(f"CVD_COLORCOPY_END=${symbols['CVD_COLORCOPY_END']:04X} exceeds $4800-$5FFF")

    if violations:
        raise SystemExit("ERROR: CVD memory layout guard failed: " + "; ".join(violations))

    print("[CVD] Memory layout guard OK")



# ============================================================================
# Prebuild Checks
# ============================================================================

def iter_sources(root: Path, globs: Sequence[str]) -> list[Path]:
    out: list[Path] = []
    for g in globs:
        out.extend(root.rglob(g))
    return [p for p in out if p.is_file()]


def count_regex_in_files(files: Iterable[Path], pattern: re.Pattern[str]) -> int:
    cnt = 0
    for f in files:
        try:
            text = f.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        cnt += len(pattern.findall(text))
    return cnt


def prebuild_checks(ctx: Context) -> None:
    """
    Python port of PreBuild.bat:
    - CartZpMap.inc must be included exactly once and only from
      Loader/CartLibStream.s.
    - CartLibCommon.s must be included exactly once and only from Loader/CartLib.s.
    - Plugins must NOT include either directly.
    """
    pat_zpmap = re.compile(r"^[ \t]*\.include[ \t]+.*CartZpMap\.inc", re.IGNORECASE | re.MULTILINE)
    pat_common = re.compile(r"^[ \t]*\.include[ \t]+.*CartLibCommon\.s", re.IGNORECASE | re.MULTILINE)

    all_sources = iter_sources(ctx.irq_root, ["*.s", "*.inc"])
    all_sources = [p for p in all_sources if not str(p).startswith(str(ctx.build_dir))]

    cnt_zpmap = count_regex_in_files(all_sources, pat_zpmap)
    cnt_common = count_regex_in_files(all_sources, pat_common)

    stream_file = ctx.irq_root / "Loader" / "CartLibStream.s"
    root_file = ctx.irq_root / "Loader" / "CartLib.s"

    cnt_zpmap_stream = count_regex_in_files([stream_file], pat_zpmap)
    cnt_common_root = count_regex_in_files([root_file], pat_common)

    failed = False
    if cnt_zpmap != 1:
        print(f"ERROR: CartZpMap.inc include count is {cnt_zpmap} (expected: 1 — CartLibStream.s)")
        failed = True
    if cnt_zpmap_stream != 1:
        print(f"ERROR: CartZpMap.inc must be included from Loader/CartLibStream.s (expected: 1 match there)")
        failed = True
    if cnt_common != 1:
        print(f"ERROR: CartLibCommon.s include count is {cnt_common} (expected: 1)")
        failed = True
    if cnt_common_root != 1:
        print(f"ERROR: CartLibCommon.s must be included from Loader/CartLib.s (expected: 1 match there)")
        failed = True

    plugin_sources = iter_sources(ctx.irq_root / "Plugins", ["*.s", "*.inc"])
    if count_regex_in_files(plugin_sources, pat_zpmap) != 0:
        print("ERROR: Plugins must NOT include CartZpMap.inc directly.")
        failed = True
    if count_regex_in_files(plugin_sources, pat_common) != 0:
        print("ERROR: Plugins must NOT include CartLibCommon.s directly.")
        failed = True

    if failed:
        print("       Fix the include chain. Do not add include-guards.")
        raise SystemExit(1)

    print("[PREBUILD] OK")


# ============================================================================
# C64 Build Functions
# ============================================================================

PLUGIN_MATRIX = [
    # (rel_path_from_irq_root, asm_file, out_basename)
    ("Plugins/CvdPlayer",               "CvdPlayer.s",        "cvdplugin"),
    ("Plugins/KoalaDisplayer",          "KoalaDisplayer.s",   "koaplugin"),
    ("Plugins/WavPlayer",               "WavPlayer.s",        "wavplugin"),
    ("Loader/Bridges/KernalBridge",     "KernalBridge.s",     "prgplugin"),
]

def clean(ctx: Context) -> None:
    if ctx.build_dir.exists():
        print("[CLEAN] Removing C64 build artifacts...")
        clear_hidden_tree(ctx.build_dir)
        try:
            shutil.rmtree(ctx.build_dir)
        except PermissionError:
            # OneDrive may hold locks on empty dirs — remove files first,
            # then retry directories ignoring any still-locked empty dirs.
            for root, dirs, files in os.walk(ctx.build_dir, topdown=False):
                for f in files:
                    try:
                        os.remove(os.path.join(root, f))
                    except OSError:
                        pass
                for d in dirs:
                    try:
                        os.rmdir(os.path.join(root, d))
                    except OSError:
                        pass
    print("[CLEAN] Done.")


def build_core(ctx: Context, *, build_arduino: bool, arduino_debug: int, menu_prg_name: str, release_log: bool = False) -> None:
    ensure_dirs(ctx)
    prebuild_checks(ctx)

    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])

    # Convert PETMATE frame export -> raw binary for .binary include
    petmate_asm = ctx.irq_root / "Menu" / "EasySD" / "petmate frame.asm"
    petmate_bin = ctx.build_dir / "menu.bin"
    if petmate_asm.exists():
        convert_petmate_asm(petmate_asm, petmate_bin)
    else:
        print(f"WARNING: {petmate_asm} not found, skipping PETMATE conversion")

    # Menu asm -> prg
    menu_src = ctx.irq_root / "Menu" / "EasySD" / "EasySDMenu.s"
    out_prg = ctx.build_dir / menu_prg_name
    labels = ctx.sym_dir / "easysd.txt"
    listing = ctx.lst_dir / "easysdLst.txt"
    print(f"[CORE] 64tass: {menu_src.relative_to(ctx.irq_root)}")
    run_cmd(
        [
            tass, "-c", "--long-branch",
            "-D", "DEBUG=0",
            str(menu_src),
            "-o", str(out_prg),
            "--labels", str(labels),
            "-L", str(listing),
        ],
        cwd=ctx.irq_root
    )

    if build_arduino:
        # Loader stub + IRQLoader + Warning
        stub_src = ctx.irq_root / "Loader" / "LoaderStub.65s"
        stub_bin = ctx.build_dir / "LoaderStub.65s.bin"
        print(f"[CORE] 64tass: {stub_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(stub_src), "-o", str(stub_bin), "--labels", str(ctx.sym_dir / "LoaderStub.65s.txt")], cwd=ctx.irq_root)

        irq_src = ctx.irq_root / "Loader" / "IRQLoader.65s"
        irq_bin = ctx.build_dir / "IRQLoader.65s.bin"
        irq_labels = ctx.sym_dir / "IRQLoader.txt"
        print(f"[CORE] 64tass: {irq_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(irq_src), "-o", str(irq_bin), "--labels", str(irq_labels)], cwd=ctx.irq_root)

        warn_src = ctx.irq_root / "Menu" / "WarningMenu" / "Warning.s"
        warning_prg = ctx.build_dir / "warning.prg"
        print(f"[CORE] 64tass: {warn_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "--long-branch", str(warn_src), "-o", str(warning_prg), "--labels", str(ctx.sym_dir / "Warning.s.txt")], cwd=ctx.irq_root)

        # Arduino artifact generation
        defaultmenu_h = ctx.build_dir / "defaultmenu.h"
        loaderstub_h = ctx.build_dir / "LoaderStub.h"

        bin2ardh(warning_prg, defaultmenu_h, "data_len", "cartridgeData")
        bin2ardh(stub_bin, loaderstub_h, "stub_len", "stubData")

        avr_head = ctx.irq_root / "avrincludehead.txt"
        avr_foot = ctx.irq_root / "avrincludefoot.txt"
        flashlib_h = ctx.build_dir / "FlashLib.h"

        print(f"[CORE] Generating {flashlib_h.name}")
        flashlib_h.write_bytes(
            avr_head.read_bytes()
            + defaultmenu_h.read_bytes()
            + loaderstub_h.read_bytes()
            + avr_foot.read_bytes()
        )

        if ctx.arduino_root.exists():
            shutil.copyfile(flashlib_h, ctx.arduino_root / "FlashLib.h")
            print(f"[CORE] Copied to: Arduino/EasySD/FlashLib.h")

            # Generate BuildConfig.h based on target
            arduino_generate_buildconfig(ctx, debug_mode=bool(arduino_debug), release_log=release_log)
        else:
            print(f"WARNING: Arduino target dir not found: {ctx.arduino_root}")

        eprom_out = ctx.build_dir / "IRQLoaderRom.bin"
        eprom_pos = read_irq_loader_placeholder_positions(irq_labels)
        create_eprom_loader(irq_bin, eprom_out, eprom_pos)

        print("[CORE] Arduino/EPROM artifacts generated.")

    print("[CORE] OK")


def build_plugins(ctx: Context, *, ensure_core_prereq: bool = True) -> None:
    ensure_dirs(ctx)
    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])

    print("==============================================================")
    print("[PLUGINS] Building ALL plugins")
    print("==============================================================")

    for rel_path, asm_file, out_base in PLUGIN_MATRIX:
        src = ctx.irq_root / rel_path / asm_file
        if not src.exists():
            print(f"WARNING: Plugin source not found: {src}")
            continue

        out_prg = ctx.plugins_out_dir / f"{out_base}.prg"
        labels = ctx.sym_dir / f"{out_base}.txt"
        listing = ctx.lst_dir / f"{out_base}LST.txt"
        print(f"  - {rel_path}/{asm_file} -> build/plugins/{out_base}.prg")
        run_cmd(
            [
                tass, "-c", "--long-branch",
                "-D", "DEBUG=0",
                str(src),
                "-o", str(out_prg),
                "--labels", str(labels),
                "-L", str(listing),
            ],
            cwd=ctx.irq_root
        )
        if out_base == "cvdplugin":
            validate_cvd_memory_layout(labels)

    print("[PLUGINS] OK")


# ============================================================================
# Arduino Build Functions (NEW - POST-SPRINT6)
# ============================================================================

ARDUINO_FQBN = "arduino:avr:nano:cpu=atmega328"  # Arduino Nano (ATmega328P)


def arduino_setup(ctx: Context) -> None:
    """One-time Arduino-CLI setup: install boards and libraries"""
    cli_exe = find_arduino_cli(ctx)

    print("\n" + "="*70)
    print("ARDUINO-CLI SETUP")
    print("="*70)

    # Update core index
    print("\n[1/4] Updating board index...")
    run_arduino_cli(cli_exe, ["core", "update-index"])

    # Install Arduino AVR boards
    print("\n[2/3] Installing Arduino AVR boards...")
    run_arduino_cli(cli_exe, ["core", "install", "arduino:avr"])

    # SdFat is bundled in Arduino/libraries/SdFat (2.3.0) and consumed via the
    # compile-time --libraries flag, so we don't install it into the user's
    # sketchbook to avoid version drift between machines.
    print("\n[3/3] Listing installed libraries...")
    run_arduino_cli(cli_exe, ["lib", "list"])

    print("\n" + "="*70)
    print("SETUP COMPLETE!")
    print("="*70)
    print("\nNext: python build.py arduino-compile")


def arduino_generate_buildconfig(ctx: Context, debug_mode: bool, release_log: bool = False) -> None:
    """Generate BuildConfig.h for Arduino sketch"""
    buildconfig_h = ctx.arduino_root / "BuildConfig.h"
    if debug_mode:
        buildconfig_content = "#define EASYSD_DEBUG_SERIAL\n"
        mode_str = "ON"
    elif release_log:
        buildconfig_content = "#define EASYSD_RELEASE_LOG\n"
        mode_str = "RELEASE_LOG"
    else:
        buildconfig_content = "// EASYSD_DEBUG_SERIAL disabled (release build)\n"
        mode_str = "OFF"

    buildconfig_h.write_text(buildconfig_content, encoding="utf-8")
    print(f"[ARDUINO] Generated BuildConfig.h (EASYSD_DEBUG_SERIAL={mode_str})")


def arduino_compile(ctx: Context, debug_mode: bool = False, output_dir: Path = None, release_log: bool = False) -> dict | None:
    """Compile Arduino sketch"""
    cli_exe = find_arduino_cli(ctx)
    if debug_mode:
        build_profile = "compile-debug"
    elif release_log:
        build_profile = "compile-release-log"
    else:
        build_profile = "compile-release"
    build_path, _ = prepare_arduino_cli_paths(ctx, build_profile)

    # Generate BuildConfig.h first
    arduino_generate_buildconfig(ctx, debug_mode, release_log=release_log)

    mode_label = 'ON' if debug_mode else ('RELEASE_LOG' if release_log else 'OFF')
    print("\n" + "="*70)
    print("BUILDING ARDUINO SKETCH")
    print("="*70)
    print(f"  Sketch: {ctx.arduino_root}")
    print(f"  Board: {ARDUINO_FQBN}")
    print(f"  DEBUG_SERIAL: {mode_label}")
    print("="*70)

    # Force the project-bundled SdFat 2.3.0 (Arduino/libraries/SdFat) instead
    # of whatever version sits in the user's sketchbook libraries.  This keeps
    # the build reproducible and avoids the LFN/SFN behaviour drift that hit
    # KOA media open when the user-installed SdFat differed from expectations.
    project_libs_dir = ctx.repo_root / "Arduino" / "libraries"
    compile_args = [
        "compile",
        "--fqbn", ARDUINO_FQBN,
        "--verbose",
        "--build-path", str(build_path),
        "--libraries", str(project_libs_dir),
    ]

    # Keep HardwareSerial buffers small in every firmware profile. The release
    # build does not use Serial at all, but the AVR core still reserves the
    # default 64B TX + 64B RX buffers unless these macros are set. Recovering
    # that SRAM materially improves stack headroom on ATmega328/Nano.
    serial_buffer_flags = "-DSERIAL_TX_BUFFER_SIZE=16 -DSERIAL_RX_BUFFER_SIZE=2"

    if debug_mode:
        # Log categories enabled in debug build (deploy-serial-debug.bat workflow):
        #   SYS=1   protocol/state errors (Unknown cmd, Stale ident reset, Cmd timeout, HS OK)
        #   SD=1    SD card errors (SD FAIL, SD recover FAIL)
        #   DIR=1   directory navigation issues
        #   LOAD=0  high-level [LOAD] events — disabled to fit ATmega328 flash budget
        #   FILE=0  per-file open/close — disabled to fit ATmega328 flash budget
        #   NI=0    CVD NI stream diagnostics — disabled to fit ATmega328 flash budget
        #   RAW=0   numeric variable prints — disabled to fit ATmega328 flash budget
        #   PRG=0   PRG-loader internal traces (verbose; not needed for KOA debugging)
        #   PROTO=0 reserved category, no log calls in code
        # See Arduino/EasySD/EasySDLog.h for the full list of LOG_ENABLE_* flags.
        # With all categories enabled the debug build was ~32.4 KB (105%) and
        # would not link.  The remaining DIR+SD+SYS+ERR set is sufficient for
        # the navigation/protocol debugging workflow.
        log_flags = (
            "-DLOG_ENABLE_SYS=1 -DLOG_ENABLE_SD=1 -DLOG_ENABLE_DIR=1 "
            "-DLOG_ENABLE_LOAD=0 -DLOG_ENABLE_FILE=0 -DLOG_ENABLE_NI=0 "
            "-DLOG_ENABLE_RAW=0 -DLOG_ENABLE_PRG=0 -DLOG_ENABLE_PROTO=0"
        )
        common_flags = f"{serial_buffer_flags} {log_flags}"
    else:
        common_flags = serial_buffer_flags

    compile_args += [
        "--build-property", f"compiler.cpp.extra_flags={common_flags}",
        "--build-property", f"compiler.c.extra_flags={common_flags}",
    ]

    if output_dir is not None:
        output_dir.mkdir(parents=True, exist_ok=True)
        compile_args += ["--output-dir", str(output_dir)]
    compile_args.append(str(ctx.arduino_root))

    result = run_arduino_cli(cli_exe, compile_args)

    print("\n" + "="*70)
    print("ARDUINO BUILD COMPLETE!")
    print("="*70)
    size = parse_arduino_size(result.stdout)
    if size:
        print_size_summary(size)
        cache = default_arduino_compile_dir(ctx) / "size_cache.json"
        cache.write_text(json.dumps(size))
    return size


def find_avrdude(ctx: Context) -> tuple[Path, Path]:
    """Find avrdude executable and config in Arduino15 packages"""
    arduino15 = Path.home() / "AppData" / "Local" / "Arduino15"
    avrdude_bins = sorted(arduino15.glob("packages/arduino/tools/avrdude/*/bin/avrdude.exe"))
    avrdude_confs = sorted(arduino15.glob("packages/arduino/tools/avrdude/*/etc/avrdude.conf"))
    if not avrdude_bins or not avrdude_confs:
        raise SystemExit(
            "ERROR: avrdude not found in Arduino15 packages.\n"
            "Run: python build.py arduino-setup"
        )
    return avrdude_bins[-1], avrdude_confs[-1]


def resolve_existing_arduino_hex(ctx: Context) -> Path:
    """Return the default Arduino HEX artifact produced by release/arduino-compile."""
    compile_dir = default_arduino_compile_dir(ctx)
    hex_file = compile_dir / "EasySD.ino.hex"
    if not hex_file.exists():
        raise SystemExit(
            "ERROR: Existing Arduino HEX not found.\n"
            f"Expected: {hex_file}\n"
            "Run: python build.py release  or  python build.py arduino-compile"
        )
    return hex_file


def arduino_upload_isp(ctx: Context, sck_period: int = 10, debug_mode: bool = False,
                       release_log: bool = False, use_existing: bool = False) -> None:
    """Upload Arduino sketch via ISP programmer (USBTinyISP).

    Always sets BOOTRST=1 (hfuse 0xDB) so the CPU starts from $0000 (application)
    with no bootloader. Optiboot is intentionally unsupported — its ~1-2s boot
    window leaves /RESET and EXROM floating, which breaks the EasySD cold-boot
    sequence that must hold the C64 in reset until the AVR is fully initialised.
    """
    if use_existing:
        hex_file = resolve_existing_arduino_hex(ctx)
        size = None
    else:
        import tempfile
        output_dir = Path(tempfile.gettempdir()) / "easysd_isp_output"
        reset_dir(output_dir)
        size = arduino_compile(ctx, debug_mode=debug_mode, output_dir=output_dir, release_log=release_log)
        hex_file = output_dir / "EasySD.ino.hex"

    avrdude_exe, avrdude_conf = find_avrdude(ctx)
    if not hex_file.exists():
        raise SystemExit(f"ERROR: HEX file not found: {hex_file}")

    print("\n" + "="*70)
    print("UPLOADING VIA ISP (USBTinyISP)")
    print("="*70)
    print(f"  HEX:        {hex_file.name}")
    print(f"  Source:     {'existing build artifact' if use_existing else 'fresh compile'}")
    print(f"  Programmer: usbtinyisp")
    print(f"  SCK period: {sck_period} µs  ({1000 // sck_period} kHz)")
    print(f"  DEBUG_SERIAL: {'ON' if debug_mode else ('RELEASE_LOG' if release_log else 'OFF')}")
    print("="*70)

    run_cmd(
        [
            str(avrdude_exe),
            f"-C{avrdude_conf}",
            "-v",
            "-p", "atmega328p",
            "-c", "usbtiny",
            f"-B{sck_period}",
            f"-Uflash:w:{hex_file}:i",
        ],
        cwd=ctx.repo_root
    )

    # Set BOOTRST=1 so CPU starts from $0000 (application), not from the boot
    # section ($7E00). Without this fuse, the chip jumps to $7E00 on reset —
    # if no bootloader is present there, it hangs.
    print("\n" + "="*70)
    print("SETTING FUSE: BOOTRST=1 (application start, no bootloader)")
    print("="*70)
    run_cmd(
        [
            str(avrdude_exe),
            f"-C{avrdude_conf}",
            "-v",
            "-p", "atmega328p",
            "-c", "usbtiny",
            f"-B{sck_period}",
            "-D",
            "-Uhfuse:w:0xDB:m",  # BOOTRST=1: start from $0000
        ],
        cwd=ctx.repo_root
    )

    print("\n" + "="*70)
    print("ISP UPLOAD COMPLETE!")
    print("="*70)
    if size:
        print_size_summary(size)


def arduino_monitor(ctx: Context, port: str, baudrate: int = 57600) -> None:
    """Open serial monitor"""
    cli_exe = find_arduino_cli(ctx)

    print("\n" + "="*70)
    print("SERIAL MONITOR")
    print("="*70)
    print(f"  Port: {port}")
    print(f"  Baudrate: {baudrate}")
    print("="*70)
    print("\nPress Ctrl+C to exit\n")

    run_arduino_cli(cli_exe, [
        "monitor",
        "--port", port,
        "--config", f"baudrate={baudrate}",
        "--raw"
    ], check=False)


def arduino_list_ports(ctx: Context) -> None:
    """List available COM ports"""
    cli_exe = find_arduino_cli(ctx)
    print("\nAvailable ports:")
    run_arduino_cli(cli_exe, ["board", "list"])


def arduino_clean(ctx: Context) -> None:
    """Clean Arduino temp files"""
    cli_exe = find_arduino_cli(ctx)
    print("\n[ARDUINO-CLEAN] Cleaning temporary files...")

    # arduino-cli compile creates temp directories, but we can delete sketch build cache
    # The cache is typically in user's temp directory, managed by arduino-cli
    print("[ARDUINO-CLEAN] Sketch cache is managed by arduino-cli automatically.")
    print("[ARDUINO-CLEAN] Use 'arduino-cli cache clean' for deep clean if needed.")


# ============================================================================
# Argument Parsing
# ============================================================================

def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="build.py",
        description="EasySD Unified Professional Build System",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # C64 builds
  python build.py release              # Full release bundles (release/upload/sd-content)
  python build.py sd-content           # Build/sync SD content bundle in build/sd-content

  # Arduino operations
  python build.py arduino-setup        # One-time setup
  python build.py arduino-compile      # Compile + upload bundle in build/upload
  python build.py arduino-compile --debug  # Compile (debug mode - SERIAL ON)
    python build.py arduino-upload-isp                # Compile + Upload (ISP/USBTinyISP)
    python build.py arduino-upload-isp --debug        # Upload debug firmware (SERIAL ON)
    python build.py arduino-upload-isp --use-existing # Upload existing build/_arduino-compile/EasySD.ino.hex
    python build.py arduino-upload-isp --isp-sck 10  # ISP with custom SCK period (µs)
    python build.py arduino-monitor COM4              # Serial monitor
        """
    )

    p.add_argument(
        "target",
        nargs='?',
        default="release",
        choices=[
            # C64 builds
            "release",
            "core", "plugins", "clean", "prebuild",
            # Arduino operations
            "arduino-setup", "arduino-compile", "arduino-upload-isp",
            "arduino-monitor", "arduino-list-ports", "arduino-clean", "arduino-size",
            # SD card deploy
            "sd-deploy", "sd-content",
        ],
        help="Build target"
    )

    # Port/drive argument (COM port for Arduino, drive letter for sd-deploy)
    p.add_argument("port", nargs='?', default=None, help="COM port for Arduino upload/monitor (e.g. COM4), or drive letter for sd-deploy (e.g. D:)")

    # Options
    p.add_argument("--debug", action="store_true", help="Arduino debug firmware (SERIAL ON) for arduino-compile / arduino-upload-isp")
    p.add_argument("--skip-arduino", action="store_true", help="Skip Arduino/EPROM artifacts in C64 builds")
    p.add_argument("--menu-prg-name", default=None, help="Override menu PRG output name")
    p.add_argument("--baudrate", type=int, default=57600, help="Baudrate for serial monitor (default: 57600)")
    p.add_argument("--isp-sck", type=int, default=2, metavar="USEC",
                   help="ISP SCK period in µs for arduino-upload-isp (default: 2 = 500kHz, use 100 for blank/bricked chips)")
    p.add_argument("--use-existing", action="store_true",
                   help="Reuse build/_arduino-compile/EasySD.ino.hex instead of recompiling for arduino-upload-isp")
    p.add_argument("--release-log", action="store_true",
                   help="Enable lightweight serial logging in release builds (DIR/SYS/SD/ERR categories only)")
    return p.parse_args(list(argv))


# ============================================================================
# Main
# ============================================================================

def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    ctx = make_context()

    # ==================================================
    # Arduino operation targets
    # ==================================================

    if args.target == "arduino-setup":
        arduino_setup(ctx)
        return 0

    if args.target == "arduino-compile":
        compile_dir = default_arduino_compile_dir(ctx)
        arduino_compile(ctx, debug_mode=args.debug, output_dir=compile_dir, release_log=args.release_log)
        mode_label = "DEBUG" if args.debug else ("RELEASE_LOG" if args.release_log else "RELEASE")
        stage_upload_bundle(ctx, compile_dir, mode_label=mode_label)
        return 0

    if args.target == "arduino-upload-isp":
        arduino_upload_isp(ctx, sck_period=args.isp_sck, debug_mode=args.debug,
                           release_log=args.release_log,
                           use_existing=args.use_existing)
        return 0

    if args.target == "arduino-monitor":
        if not args.port:
            print("\nERROR: COM port required for arduino-monitor")
            arduino_list_ports(ctx)
            print("\nUsage: python build.py arduino-monitor COM4")
            return 1
        arduino_monitor(ctx, args.port, baudrate=args.baudrate)
        return 0

    if args.target == "arduino-list-ports":
        arduino_list_ports(ctx)
        return 0

    if args.target == "arduino-clean":
        arduino_clean(ctx)
        return 0

    if args.target == "arduino-size":
        cache = default_arduino_compile_dir(ctx) / "size_cache.json"
        if not cache.exists():
            print("No size data — run 'python build.py release' or 'python build.py arduino-compile' first.")
            return 1
        print_size_summary(json.loads(cache.read_text()))
        return 0

    if args.target == "sd-content":
        stage_sd_content_bundle(ctx, preferred_menu_name="easysd.prg")
        return 0

    if args.target == "sd-deploy":
        drive = (args.port or "D:").strip()
        if re.fullmatch(r"[A-Za-z]:", drive):
            drive_root = Path(f"{drive}\\")
        else:
            drive_root = Path(drive)
        plugins_dir = drive_root / "PLUGINS"
        if not drive_root.exists():
            print(f"ERROR: {drive_root} not found — is the SD card mounted as {drive}?")
            return 1
        plugins_dir.mkdir(parents=True, exist_ok=True)
        copied = 0

        expected_menu = "easysd.prg"

        # Prefer the full release bundle, but allow the standalone sd-content bundle.
        candidate_roots: list[Path] = [ctx.build_dir / "release" / "sd-content", ctx.build_dir / "sd-content"]

        sd_bundle_root = None
        for root in candidate_roots:
            menu_file = root / "EASYSD.PRG"
            if not menu_file.exists():
                continue
            manifest_menu = read_manifest_value(root / "manifest.txt", "menu")
            # If manifest exists, enforce matching mode.
            if manifest_menu and manifest_menu.lower() != expected_menu.lower():
                continue
            sd_bundle_root = root
            break

        use_bundle = sd_bundle_root is not None

        # EASYSD.PRG → SD root (required: TransferMenu() loads menu from SD)
        menu_src = (sd_bundle_root / "EASYSD.PRG") if use_bundle else (ctx.build_dir / expected_menu)
        if menu_src.exists():
            dst = drive_root / "EASYSD.PRG"
            copyfile_for_bundle(menu_src, dst, hidden=True)
            print(f"[SD-DEPLOY] {menu_src.name} -> {dst}")
            copied += 1
        else:
            print(f"WARNING: {menu_src} not found — run 'python build.py release' first")

        # Plugin PRGs → D:/PLUGINS/*.PRG
        if use_bundle:
            src_dir = sd_bundle_root / "PLUGINS"
            src_plugins = sorted(src_dir.glob("*.PRG"))
        else:
            src_dir = ctx.plugins_out_dir
            src_plugins = sorted(src_dir.glob("*.prg"))

        if not src_plugins:
            print(f"ERROR: No plugin PRG files in {src_dir} — run 'python build.py release' or 'python build.py plugins' first")
            return 1
        print(f"[SD-DEPLOY] {src_dir} -> {plugins_dir}")
        for src in src_plugins:
            dst = plugins_dir / src.name.upper()
            copyfile_for_bundle(src, dst, hidden=True)
            print(f"  {src.name} -> {dst.name}")
            copied += 1
        mark_sd_system_items_hidden(drive_root)
        print(f"[SD-DEPLOY] {copied} file(s) copied. OK")
        return 0

    # ==================================================
    # C64-only targets
    # ==================================================

    build_arduino = (args.target in ("release", "core")) and (not args.skip_arduino)

    menu_prg_name = args.menu_prg_name or "easysd.prg"

    print("==============================================================")
    print(f"EasySD BUILD ({args.target.upper() if args.target else 'RELEASE'})")
    print(f"  repo_root = {ctx.repo_root}")
    print(f"  irq_root  = {ctx.irq_root}")
    print(f"  tools_dir = {ctx.tools_dir}")
    print(f"  BUILD_ARDUINO={1 if build_arduino else 0}")
    print("==============================================================")

    if args.target == "clean":
        clean(ctx)
        return 0

    if args.target == "prebuild":
        prebuild_checks(ctx)
        return 0

    if args.target == "core":
        build_core(ctx, build_arduino=build_arduino, arduino_debug=0, menu_prg_name=menu_prg_name, release_log=args.release_log)
        return 0

    if args.target == "plugins":
        build_plugins(ctx)
        return 0

    if args.target == "release":
        clean(ctx)
        build_core(ctx, build_arduino=build_arduino, arduino_debug=0, menu_prg_name=menu_prg_name, release_log=args.release_log)
        build_plugins(ctx, ensure_core_prereq=False)
        stage_sd_content_bundle(ctx, preferred_menu_name=menu_prg_name)
        upload_mode = "RELEASE_LOG" if args.release_log else "RELEASE"
        if not args.skip_arduino:
            compile_dir = default_arduino_compile_dir(ctx)
            arduino_compile(ctx, debug_mode=False, output_dir=compile_dir, release_log=args.release_log)
            stage_upload_bundle(ctx, compile_dir, mode_label=upload_mode)
        stage_release_bundle(
            ctx,
            preferred_menu_name=menu_prg_name,
            mode_label=("C64_ONLY" if args.skip_arduino else upload_mode),
            include_upload=(not args.skip_arduino),
        )
        print("==============================================================")
        print(f"BUILD SUCCESSFUL (RELEASE)")
        print(f"Output: {ctx.build_dir / menu_prg_name}")
        print(f"SD bundle: {ctx.build_dir / 'sd-content'}")
        if not args.skip_arduino:
            print(f"Upload bundle: {ctx.build_dir / 'upload'}")
        print(f"Release bundle: {ctx.build_dir / 'release'}")
        print("==============================================================")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
