#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
EasySD / IRQHack64 - Unified Professional Build System

Supports C64 and Arduino builds from a single command-line interface.

Usage Examples:
  # C64 builds
  python build.py release              # C64 release + Arduino BuildConfig (serial OFF)
  python build.py debug-vice           # C64 VICE debug + Arduino BuildConfig (serial OFF)
  python build.py debug-arduino        # C64 debug + Arduino BuildConfig (serial ON)

  # Arduino operations
  python build.py arduino-setup        # One-time Arduino-CLI setup
  python build.py arduino-compile      # Compile Arduino (release mode)
  python build.py arduino-compile --debug  # Compile Arduino (debug mode - SERIAL ON)
  python build.py arduino-upload COM4  # Compile + Upload to port
  python build.py arduino-monitor COM4 # Serial monitor (57600 baud)
  python build.py arduino-clean        # Clean Arduino temp files

  # Full workflow
  python build.py all                  # Build C64 + Arduino (release)
  python build.py all --debug          # Build C64 + Arduino (debug)

Author: Claude Sonnet 4.5 (POST-SPRINT6)
Version: 3.0.0
Date: 2025-12-26
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


# ============================================================================
# Platform & Utilities
# ============================================================================

def is_windows() -> bool:
    return os.name == "nt"


def find_repo_root(start: Path) -> Path:
    """
    Find repo root by locating sibling directories: Tools + Arduino + IRQHack64.
    """
    p = start.resolve()
    for candidate in [p, *p.parents]:
        if (candidate / "Tools").is_dir() and (candidate / "Arduino").is_dir() and (candidate / "IRQHack64").is_dir():
            return candidate
    raise SystemExit(
        "ERROR: Could not locate repo root. Expected directories: Tools/, Arduino/, IRQHack64/.\n"
        "Run from inside the repo."
    )


# ============================================================================
# Context
# ============================================================================

@dataclass(frozen=True)
class Context:
    repo_root: Path
    irq_root: Path         # <repo_root>/IRQHack64
    arduino_root: Path     # <repo_root>/Arduino/IRQHack64
    tools_dir: Path        # <repo_root>/Tools
    build_dir: Path        # <irq_root>/build
    sym_dir: Path
    lst_dir: Path
    plugins_out_dir: Path


def make_context() -> Context:
    here = Path(__file__).resolve()
    repo_root = find_repo_root(here.parent)
    irq_root = repo_root / "IRQHack64"
    arduino_root = repo_root / "Arduino" / "IRQHack64"
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
    """Run arduino-cli command"""
    cmd = [str(cli_exe)] + args
    print(f"\n> {' '.join(cmd)}")
    return subprocess.run(cmd, check=check)


# ============================================================================
# File Operations
# ============================================================================

def ensure_dirs(ctx: Context) -> None:
    ctx.build_dir.mkdir(exist_ok=True)
    ctx.sym_dir.mkdir(exist_ok=True)
    ctx.lst_dir.mkdir(exist_ok=True)
    ctx.plugins_out_dir.mkdir(exist_ok=True)


def concat_files(out_path: Path, *inputs: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as w:
        for ip in inputs:
            with ip.open("rb") as r:
                shutil.copyfileobj(r, w)


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
    - CartZpMap.inc must be included exactly once and only from Loader/CartLibStream.s
    - CartLibCommon.s must be included exactly once and only from Loader/CartLib.s
    - Plugins must NOT include either directly
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
        print(f"ERROR: CartZpMap.inc include count is {cnt_zpmap} (expected: 1)")
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
    # (plugin_dir, asm_file, out_basename)
    ("CvidPlayer", "CvidPlayer.s", "cvidplugin"),
    ("KoalaDisplayer", "KoalaDisplayer.s", "koaplugin"),
    ("PetsciiDisplayer", "PetsciiDisplayer.s", "petgplugin"),
    ("PrgPlugin", "PrgPlugin.s", "prgplugin"),
    ("WavPlayer", "WavPlayer.s", "wavplugin"),
    ("MusPlayer", "MusPlayer.s", "musplugin"),
]


def clean(ctx: Context) -> None:
    if ctx.build_dir.exists():
        print("[CLEAN] Removing C64 build artifacts...")
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


def build_core(ctx: Context, *, debug: int, debug_break: int, build_arduino: bool, arduino_debug: int, menu_prg_name: str) -> None:
    ensure_dirs(ctx)
    prebuild_checks(ctx)

    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])
    petcat = resolve_tool(ctx, ["petcat", "petcat.exe"])

    # BASIC header -> build/IrqLoaderMenu.obj
    bas_src = ctx.irq_root / "Menus" / "EasySD" / "IrqLoaderMenu.bas"
    bas_obj = ctx.build_dir / "IrqLoaderMenu.obj"
    print(f"[CORE] petcat: {bas_src.relative_to(ctx.irq_root)}")
    with bas_src.open("rb") as r, bas_obj.open("wb") as w:
        p = subprocess.run([str(petcat), "-w2"], stdin=r, stdout=w, cwd=str(ctx.irq_root))
    if p.returncode != 0:
        raise SystemExit(p.returncode)

    # Convert PETMATE frame export -> raw binary for .binary include
    petmate_asm = ctx.irq_root / "Menus" / "EasySD" / "menu.asm"
    petmate_bin = ctx.irq_root / "Menus" / "EasySD" / "menu.bin"
    if petmate_asm.exists():
        convert_petmate_asm(petmate_asm, petmate_bin)
    else:
        print(f"WARNING: {petmate_asm} not found, skipping PETMATE conversion")

    # Menu asm -> bin
    menu_src = ctx.irq_root / "Menus" / "EasySD" / "IrqLoaderMenuNew.s"
    menu_bin = ctx.build_dir / "IrqLoaderMenuNew.bin"
    labels = ctx.sym_dir / "IrqLoaderMenuNew.txt"
    vice_labels = ctx.sym_dir / "IrqLoaderMenuNew.vs"
    listing = ctx.lst_dir / "IrqLoaderMenuNewLst.txt"
    print(f"[CORE] 64tass: {menu_src.relative_to(ctx.irq_root)}")
    run_cmd(
        [
            tass, "-c", "-b", "--long-branch",
            "-D", f"DEBUG={debug}",
            "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
            str(menu_src),
            "-o", str(menu_bin),
            "--labels", str(labels),
            "-L", str(listing),
        ],
        cwd=ctx.irq_root
    )
    # Generate VICE-format labels for binary monitor / test_vice_menu.py
    run_cmd(
        [
            tass, "-c", "-b", "--long-branch",
            "-D", f"DEBUG={debug}",
            "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
            str(menu_src),
            "-o", os.devnull,
            "--vice-labels",
            "--labels", str(vice_labels),
        ],
        cwd=ctx.irq_root
    )

    # Link: obj + menu_bin -> menu_prg
    out_prg = ctx.build_dir / menu_prg_name
    print(f"[CORE] link: build/{menu_prg_name}")
    concat_files(out_prg, bas_obj, menu_bin)
    menu_bin.unlink(missing_ok=True)

    if build_arduino:
        # KeyBooter (if it exists)
        key_src = ctx.irq_root / "Menus" / "Keybooter" / "KeyBooter.s"
        if key_src.exists():
            print(f"[CORE] 64tass: {key_src.relative_to(ctx.irq_root)}")
            key_bin = ctx.build_dir / "KeyBooter.s.bin"
            run_cmd([tass, "-c", "-b", str(key_src), "-o", str(key_bin), "--labels", str(ctx.sym_dir / "KeyBooter.txt")], cwd=ctx.irq_root)
            concat_files(ctx.build_dir / "keybooter.prg", bas_obj, key_bin)
            key_bin.unlink(missing_ok=True)

        # Loader stub + IRQLoader + Warning
        stub_src = ctx.irq_root / "Loader" / "LoaderStub.65s"
        stub_bin = ctx.build_dir / "LoaderStub.65s.bin"
        print(f"[CORE] 64tass: {stub_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(stub_src), "-o", str(stub_bin), "--labels", str(ctx.sym_dir / "LoaderStub.65s.txt")], cwd=ctx.irq_root)

        irq_src = ctx.irq_root / "Loader" / "IRQLoader.65s"
        irq_bin = ctx.build_dir / "IRQLoader.65s.bin"
        print(f"[CORE] 64tass: {irq_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(irq_src), "-o", str(irq_bin), "--labels", str(ctx.sym_dir / "IRQLoader.txt")], cwd=ctx.irq_root)

        warn_src = ctx.irq_root / "Menus" / "WarningMenu" / "Warning.s"
        warn_bin = ctx.build_dir / "Warning.bin"
        print(f"[CORE] 64tass: {warn_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(warn_src), "-o", str(warn_bin), "--labels", str(ctx.sym_dir / "Warning.s.txt")], cwd=ctx.irq_root)

        warning_prg = ctx.build_dir / "warning.prg"
        concat_files(warning_prg, bas_obj, warn_bin)
        warn_bin.unlink(missing_ok=True)

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
            print(f"[CORE] Copied to: Arduino/IRQHack64/FlashLib.h")

            # Generate BuildConfig.h based on target
            buildconfig_h = ctx.arduino_root / "BuildConfig.h"
            if arduino_debug:
                buildconfig_content = "#define EASYSD_DEBUG_SERIAL\n"
            else:
                buildconfig_content = "// EASYSD_DEBUG_SERIAL disabled (release build)\n"
            buildconfig_h.write_text(buildconfig_content, encoding="utf-8")
            print(f"[CORE] Generated BuildConfig.h (EASYSD_DEBUG_SERIAL={'ON' if arduino_debug else 'OFF'})")
        else:
            print(f"WARNING: Arduino target dir not found: {ctx.arduino_root}")

        eprom_out = ctx.build_dir / "IRQLoaderRom.bin"
        eprom_pos = [171, 166, 103, 141, 121, 151, 146, 161, 156, 195, 176, 255]
        create_eprom_loader(irq_bin, eprom_out, eprom_pos)

        print("[CORE] Arduino/EPROM artifacts generated.")

    if not (ctx.build_dir / "IrqLoaderMenu.obj").exists():
        raise SystemExit("ERROR: build/IrqLoaderMenu.obj missing (plugins need it).")

    print("[CORE] OK")


def build_plugins(ctx: Context, *, debug: int, debug_break: int, ensure_core_prereq: bool = True) -> None:
    ensure_dirs(ctx)

    bas_obj = ctx.build_dir / "IrqLoaderMenu.obj"
    if ensure_core_prereq and not bas_obj.exists():
        print("[PLUGINS] Missing build/IrqLoaderMenu.obj -> building core prereq (no Arduino)...")
        build_core(ctx, debug=debug, debug_break=debug_break, build_arduino=False, arduino_debug=0,
                   menu_prg_name=("irqhack64-debug.prg" if debug else "irqhack64.prg"))

    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])

    print("==============================================================")
    print("[PLUGINS] Building ALL plugins")
    print(f"  DEBUG={debug}")
    print(f"  DEBUG_BREAK_AFTER_LOAD={debug_break}")
    print("==============================================================")

    for plugin_dir, asm_file, out_base in PLUGIN_MATRIX:
        src = ctx.irq_root / "Plugins" / plugin_dir / asm_file
        if not src.exists():
            print(f"WARNING: Plugin source not found: {src}")
            continue

        out_bin = ctx.plugins_out_dir / f"{out_base}.bin"
        out_prg = ctx.plugins_out_dir / f"{out_base}.prg"
        labels = ctx.sym_dir / f"{out_base}.txt"
        listing = ctx.lst_dir / f"{out_base}LST.txt"
        print(f"  - {plugin_dir} -> build/plugins/{out_base}.prg")
        run_cmd(
            [
                tass, "-c", "-b",
                "-D", f"DEBUG={debug}",
                "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
                str(src),
                "-o", str(out_bin),
                "--labels", str(labels),
                "-L", str(listing),
            ],
            cwd=ctx.irq_root
        )
        concat_files(out_prg, bas_obj, out_bin)
        out_bin.unlink(missing_ok=True)

    print("[PLUGINS] OK")


# ============================================================================
# Arduino Build Functions (NEW - POST-SPRINT6)
# ============================================================================

ARDUINO_FQBN = "arduino:avr:nano:cpu=atmega328old"  # Arduino Nano (ATmega328P, Old Bootloader)


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
    print("\n[2/4] Installing Arduino AVR boards...")
    run_arduino_cli(cli_exe, ["core", "install", "arduino:avr"])

    # Install SdFat library
    print("\n[3/4] Installing libraries...")
    run_arduino_cli(cli_exe, ["lib", "install", "SdFat"], check=False)

    print("\n[4/4] Listing installed libraries...")
    run_arduino_cli(cli_exe, ["lib", "list"])

    print("\n" + "="*70)
    print("SETUP COMPLETE!")
    print("="*70)
    print("\nNext: python build.py arduino-compile")


def arduino_generate_buildconfig(ctx: Context, debug_mode: bool) -> None:
    """Generate BuildConfig.h for Arduino sketch"""
    buildconfig_h = ctx.arduino_root / "BuildConfig.h"
    if debug_mode:
        buildconfig_content = "#define EASYSD_DEBUG_SERIAL\n"
    else:
        buildconfig_content = "// EASYSD_DEBUG_SERIAL disabled (release build)\n"

    buildconfig_h.write_text(buildconfig_content, encoding="utf-8")
    print(f"[ARDUINO] Generated BuildConfig.h (EASYSD_DEBUG_SERIAL={'ON' if debug_mode else 'OFF'})")


def arduino_compile(ctx: Context, debug_mode: bool = False) -> None:
    """Compile Arduino sketch"""
    cli_exe = find_arduino_cli(ctx)

    # Generate BuildConfig.h first
    arduino_generate_buildconfig(ctx, debug_mode)

    print("\n" + "="*70)
    print("BUILDING ARDUINO SKETCH")
    print("="*70)
    print(f"  Sketch: {ctx.arduino_root}")
    print(f"  Board: {ARDUINO_FQBN}")
    print(f"  DEBUG_SERIAL: {'ON' if debug_mode else 'OFF'}")
    print("="*70)

    run_arduino_cli(cli_exe, [
        "compile",
        "--fqbn", ARDUINO_FQBN,
        "--verbose",
        str(ctx.arduino_root)
    ])

    print("\n" + "="*70)
    print("ARDUINO BUILD COMPLETE!")
    print("="*70)


def arduino_upload(ctx: Context, port: str, debug_mode: bool = False) -> None:
    """Compile and upload Arduino sketch"""
    cli_exe = find_arduino_cli(ctx)

    # Generate BuildConfig.h first
    arduino_generate_buildconfig(ctx, debug_mode)

    print("\n" + "="*70)
    print("UPLOADING TO ARDUINO")
    print("="*70)
    print(f"  Sketch: {ctx.arduino_root}")
    print(f"  Board: {ARDUINO_FQBN}")
    print(f"  Port: {port}")
    print(f"  DEBUG_SERIAL: {'ON' if debug_mode else 'OFF'}")
    print("="*70)

    run_arduino_cli(cli_exe, [
        "compile",
        "--upload",
        "--fqbn", ARDUINO_FQBN,
        "--port", port,
        "--verbose",
        str(ctx.arduino_root)
    ])

    print("\n" + "="*70)
    print("UPLOAD COMPLETE!")
    print("="*70)
    print("\nOpen Serial Monitor @ 57600 baud to see output")
    print(f"  python build.py arduino-monitor {port}")


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
        description="EasySD / IRQHack64 Unified Professional Build System",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # C64 builds
  python build.py release              # C64 release + Arduino BuildConfig (serial OFF)
  python build.py debug-vice           # C64 VICE debug (mock data)
  python build.py debug-arduino        # C64 debug + Arduino BuildConfig (serial ON)

  # Arduino operations
  python build.py arduino-setup        # One-time setup
  python build.py arduino-compile      # Compile (release mode)
  python build.py arduino-compile --debug  # Compile (debug mode - SERIAL ON)
  python build.py arduino-upload COM4  # Compile + Upload
  python build.py arduino-monitor COM4 # Serial monitor

  # Full workflow
  python build.py all                  # C64 + Arduino (release)
  python build.py all --debug          # C64 + Arduino (debug)
        """
    )

    p.add_argument(
        "target",
        nargs='?',
        default="release",
        choices=[
            # C64 builds
            "release", "debug-vice", "debug-arduino",
            "core", "plugins", "clean", "prebuild",
            # Arduino operations
            "arduino-setup", "arduino-compile", "arduino-upload",
            "arduino-monitor", "arduino-list-ports", "arduino-clean",
            # Combined
            "all"
        ],
        help="Build target"
    )

    # Port argument for arduino-upload and arduino-monitor
    p.add_argument("port", nargs='?', default=None, help="COM port for Arduino upload/monitor (e.g. COM4)")

    # Options
    p.add_argument("--debug", action="store_true", help="Enable DEBUG mode (C64 mock data + Arduino SERIAL ON)")
    p.add_argument("--debug-break-after-load", action="store_true", help="Set DEBUG_BREAK_AFTER_LOAD=1")
    p.add_argument("--skip-arduino", action="store_true", help="Skip Arduino/EPROM artifacts in C64 builds")
    p.add_argument("--menu-prg-name", default=None, help="Override menu PRG output name")
    p.add_argument("--baudrate", type=int, default=57600, help="Baudrate for serial monitor (default: 57600)")

    return p.parse_args(list(argv))


# ============================================================================
# Main
# ============================================================================

def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    ctx = make_context()

    # ==================================================
    # Arduino-only targets
    # ==================================================

    if args.target == "arduino-setup":
        arduino_setup(ctx)
        return 0

    if args.target == "arduino-compile":
        arduino_compile(ctx, debug_mode=args.debug)
        return 0

    if args.target == "arduino-upload":
        if not args.port:
            print("\nERROR: COM port required for arduino-upload")
            arduino_list_ports(ctx)
            print("\nUsage: python build.py arduino-upload COM4")
            print("       python build.py arduino-upload COM4 --debug  (for debug mode)")
            return 1
        arduino_upload(ctx, args.port, debug_mode=args.debug)
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

    # ==================================================
    # C64-only targets
    # ==================================================

    # C64 DEBUG flag (VICE mock data)
    debug = 1 if args.target in ("debug-vice", "debug-arduino") else 0
    if args.debug and args.target not in ("arduino-compile", "arduino-upload", "all"):
        debug = 1
    debug_break = 1 if args.debug_break_after_load else 0

    # Arduino Serial DEBUG flag (only for C64 builds that generate BuildConfig.h)
    arduino_debug = 1 if args.target == "debug-arduino" else 0

    build_arduino = (args.target in ("release", "debug-vice", "debug-arduino", "core")) and (not args.skip_arduino)

    menu_prg_name = args.menu_prg_name or ("irqhack64-debug.prg" if debug else "irqhack64.prg")

    print("==============================================================")
    print(f"EasySD BUILD ({args.target.upper() if args.target else 'RELEASE'})")
    print(f"  repo_root = {ctx.repo_root}")
    print(f"  irq_root  = {ctx.irq_root}")
    print(f"  tools_dir = {ctx.tools_dir}")
    print(f"  C64_DEBUG={debug}")
    print(f"  EASYSD_DEBUG_SERIAL={arduino_debug}")
    print(f"  DEBUG_BREAK_AFTER_LOAD={debug_break}")
    print(f"  BUILD_ARDUINO={1 if build_arduino else 0}")
    print("==============================================================")

    if args.target == "clean":
        clean(ctx)
        return 0

    if args.target == "prebuild":
        prebuild_checks(ctx)
        return 0

    if args.target == "core":
        build_core(ctx, debug=debug, debug_break=debug_break, build_arduino=build_arduino, arduino_debug=arduino_debug, menu_prg_name=menu_prg_name)
        return 0

    if args.target == "plugins":
        build_plugins(ctx, debug=debug, debug_break=debug_break)
        return 0

    if args.target in ("release", "debug-vice", "debug-arduino"):
        clean(ctx)
        build_core(ctx, debug=debug, debug_break=debug_break, build_arduino=build_arduino, arduino_debug=arduino_debug, menu_prg_name=menu_prg_name)
        build_plugins(ctx, debug=debug, debug_break=debug_break, ensure_core_prereq=False)
        print("==============================================================")
        print(f"BUILD SUCCESSFUL ({args.target.upper()})")
        print(f"Output: {ctx.build_dir / menu_prg_name}")
        print("==============================================================")
        return 0

    # ==================================================
    # Combined target: all
    # ==================================================

    if args.target == "all":
        # Build C64
        c64_debug = 1 if args.debug else 0
        arduino_debug_all = 1 if args.debug else 0
        menu_name = "irqhack64-debug.prg" if c64_debug else "irqhack64.prg"

        print("\n" + "="*70)
        print("BUILDING ALL: C64 + ARDUINO")
        print(f"  Mode: {'DEBUG' if args.debug else 'RELEASE'}")
        print("="*70)

        # Clean + Build C64 + Plugins
        clean(ctx)
        build_core(ctx, debug=c64_debug, debug_break=debug_break, build_arduino=True, arduino_debug=arduino_debug_all, menu_prg_name=menu_name)
        build_plugins(ctx, debug=c64_debug, debug_break=debug_break, ensure_core_prereq=False)

        # Build Arduino
        print("\n")
        arduino_compile(ctx, debug_mode=args.debug)

        print("\n" + "="*70)
        print("ALL BUILD COMPLETE!")
        print("="*70)
        print(f"  C64 output: {ctx.build_dir / menu_name}")
        print(f"  Arduino: compiled (ready to upload)")
        print("\nNext steps:")
        print(f"  python build.py arduino-upload COM4  # Upload firmware")
        print("="*70)
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
