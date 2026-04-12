#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
EasySD - Unified Professional Build System

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


def stage_sidplayer_asset(ctx: Context) -> None:
    """
    Stage the canonical external SID player binary used by MusPlayer.

    The authoritative source in this repository is Tools/ComputeSidPlayer.prg,
    which is already assembled for load address $9000 and matches the symbol
    offsets in EasySD/Plugins/MusPlayer/ComputePlayerSymbols.inc.
    """
    src = ctx.tools_dir / "ComputeSidPlayer.prg"
    dst = ctx.plugins_out_dir / "sidplayer.prg"

    if not src.exists():
        print(f"WARNING: {src} not found — SIDPLAYER.PRG will not be staged")
        return

    shutil.copyfile(src, dst)
    print(f"  - Tools/{src.name} -> build/plugins/{dst.name}")


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
    # (rel_path_from_irq_root, asm_file, out_basename)
    ("Plugins/CvdPlayer",               "CvdPlayer.s",        "cvdplugin"),
    ("Plugins/KoalaDisplayer",          "KoalaDisplayer.s",   "koaplugin"),
    ("Plugins/PetsciiDisplayer",        "PetsciiDisplayer.s", "petgplugin"),
    ("Plugins/WavPlayer",               "WavPlayer.s",        "wavplugin"),
    ("Plugins/MusPlayer",               "MusPlayer.s",        "musplugin"),
    ("Loader/Bridges/KernalBridge",     "KernalBridge.s",     "prgplugin"),
    ("Loader/Bridges/MultiLoad",        "MultiLoad.s",        "bootplugin"),
    ("Plugins/HWTest",                  "HWTest.s",           "hwtplugin"),
]

# Standalone VICE test programs (include their own BASIC stub, built as PRG directly)
VICE_TESTS = [
    # (rel_path_from_irq_root, asm_file, out_basename)
    ("Plugins/WavPlayer",                  "WavPlayerViceTest.s",  "wavtest"),
    ("Loader/Bridges/KernalBridge",        "PrgLoadViceTest.s",    "prgtest"),
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
    vice_labels = ctx.sym_dir / "easysd.vs"
    listing = ctx.lst_dir / "easysdLst.txt"
    print(f"[CORE] 64tass: {menu_src.relative_to(ctx.irq_root)}")
    run_cmd(
        [
            tass, "-c", "--long-branch",
            "-D", f"DEBUG={debug}",
            "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
            str(menu_src),
            "-o", str(out_prg),
            "--labels", str(labels),
            "-L", str(listing),
        ],
        cwd=ctx.irq_root
    )
    # Generate VICE-format labels for binary monitor / test_vice_menu.py
    run_cmd(
        [
            tass, "-c", "--long-branch",
            "-D", f"DEBUG={debug}",
            "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
            str(menu_src),
            "-o", os.devnull,
            "--vice-labels",
            "--labels", str(vice_labels),
        ],
        cwd=ctx.irq_root
    )

    if build_arduino:
        # KeyBooter (if it exists)
        key_src = ctx.irq_root / "Menu" / "Keybooter" / "KeyBooter.s"
        if key_src.exists():
            print(f"[CORE] 64tass: {key_src.relative_to(ctx.irq_root)}")
            run_cmd([tass, "-c", "--long-branch", str(key_src), "-o", str(ctx.build_dir / "keybooter.prg"), "--labels", str(ctx.sym_dir / "KeyBooter.txt")], cwd=ctx.irq_root)

        # Loader stub + IRQLoader + Warning
        stub_src = ctx.irq_root / "Loader" / "LoaderStub.65s"
        stub_bin = ctx.build_dir / "LoaderStub.65s.bin"
        print(f"[CORE] 64tass: {stub_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(stub_src), "-o", str(stub_bin), "--labels", str(ctx.sym_dir / "LoaderStub.65s.txt")], cwd=ctx.irq_root)

        irq_src = ctx.irq_root / "Loader" / "IRQLoader.65s"
        irq_bin = ctx.build_dir / "IRQLoader.65s.bin"
        print(f"[CORE] 64tass: {irq_src.relative_to(ctx.irq_root)}")
        run_cmd([tass, "-c", "-b", str(irq_src), "-o", str(irq_bin), "--labels", str(ctx.sym_dir / "IRQLoader.txt")], cwd=ctx.irq_root)

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

    print("[CORE] OK")


def build_plugins(ctx: Context, *, debug: int, debug_break: int, ensure_core_prereq: bool = True) -> None:
    ensure_dirs(ctx)
    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])

    print("==============================================================")
    print("[PLUGINS] Building ALL plugins")
    print(f"  DEBUG={debug}")
    print(f"  DEBUG_BREAK_AFTER_LOAD={debug_break}")
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
                tass, "-c", "-b", "--long-branch",
                "-D", f"DEBUG={debug}",
                "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
                "-D", "ML_DEBUG_BORDERS=0",
                str(src),
                "-o", str(out_prg),
                "--labels", str(labels),
                "-L", str(listing),
            ],
            cwd=ctx.irq_root
        )

    stage_sidplayer_asset(ctx)

    print("[PLUGINS] OK")


def build_multiload(ctx: Context, *, debug: int, debug_break: int, ml_debug_borders: int = 0) -> None:
    """Build only BOOT.PRG (MultiLoad plugin) without rebuilding all plugins."""
    ensure_dirs(ctx)
    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])
    src = ctx.irq_root / "Loader" / "Bridges" / "MultiLoad" / "MultiLoad.s"
    out_prg = ctx.plugins_out_dir / "bootplugin.prg"
    labels  = ctx.sym_dir / "bootplugin.txt"
    listing = ctx.lst_dir / "bootpluginLST.txt"

    print(f"[MULTILOAD] Building Loader/Bridges/MultiLoad/MultiLoad.s -> build/plugins/bootplugin.prg")
    if ml_debug_borders:
        print("[MULTILOAD] ML_DEBUG_BORDERS=1 — border-color markers enabled for hardware diagnostics")
    run_cmd(
        [
            tass, "-c", "-b", "--long-branch",
            "-D", f"DEBUG={debug}",
            "-D", f"DEBUG_BREAK_AFTER_LOAD={debug_break}",
            "-D", f"ML_DEBUG_BORDERS={ml_debug_borders}",
            str(src),
            "-o", str(out_prg),
            "--labels", str(labels),
            "-L", str(listing),
        ],
        cwd=ctx.irq_root
    )
    print("[MULTILOAD] OK")
    print(f"  Output: {out_prg}")
    if ml_debug_borders:
        print("  Border colors: 1=white(entry) 2=red(savestate) 3=cyan(RL_INSTALL)")
        print("                 4=purple(StartTalking) 5=green(Send) 6=blue(WaitProc)")
        print("                 7=yellow(RecvFragment) 8=orange(OpenFile ok) 9=brown(OpenFile fail)")
        print("  Last visible color before hang = the stage that hangs.")
    print("  Copy bootplugin.prg to the game directory on the SD card as EASYLOAD.PRG")


def build_vice_tests(ctx: Context) -> None:
    """Build standalone VICE test PRGs (include their own BASIC stub, no easysd.obj prepend)."""
    ensure_dirs(ctx)
    tass = resolve_tool(ctx, ["64tass", "64tass.exe"])

    vice_out_dir = ctx.build_dir / "vice-tests"
    vice_out_dir.mkdir(exist_ok=True)

    print("==============================================================")
    print("[VICE-TESTS] Building standalone VICE test programs")
    print("==============================================================")

    for rel_path, asm_file, out_base in VICE_TESTS:
        src = ctx.irq_root / rel_path / asm_file
        if not src.exists():
            print(f"WARNING: VICE test source not found: {src}")
            continue

        out_prg = vice_out_dir / f"{out_base}.prg"
        labels = ctx.sym_dir / f"{out_base}.txt"
        listing = ctx.lst_dir / f"{out_base}LST.txt"
        print(f"  - {rel_path}/{asm_file} -> build/vice-tests/{out_base}.prg")
        # No -b flag: 64tass emits 2-byte load address header → valid PRG for VICE
        run_cmd(
            [
                tass, "-c",
                str(src),
                "-o", str(out_prg),
                "--labels", str(labels),
                "-L", str(listing),
            ],
            cwd=ctx.irq_root
        )

    print("[VICE-TESTS] OK")


# ============================================================================
# Arduino Build Functions (NEW - POST-SPRINT6)
# ============================================================================

ARDUINO_FQBN = "arduino:avr:nano:cpu=atmega328"  # Arduino Nano (ATmega328P, Optiboot)


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


def arduino_generate_buildconfig(ctx: Context, debug_mode: bool, protocol_test: bool = False) -> None:
    """Generate BuildConfig.h for Arduino sketch"""
    buildconfig_h = ctx.arduino_root / "BuildConfig.h"
    if protocol_test:
        # Protocol-test build: debug serial ON, protocol test ON,
        # DIR/FILE log categories OFF to reclaim ~600B flash headroom.
        buildconfig_content = (
            "#define EASYSD_DEBUG_SERIAL\n"
            "#define EASYSD_PROTOCOL_TEST\n"
            "#define LOG_ENABLE_DIR 0\n"
            "#define LOG_ENABLE_FILE 0\n"
        )
        mode_str = "PROTOCOL_TEST"
    elif debug_mode:
        buildconfig_content = "#define EASYSD_DEBUG_SERIAL\n"
        mode_str = "ON"
    else:
        buildconfig_content = "// EASYSD_DEBUG_SERIAL disabled (release build)\n"
        mode_str = "OFF"

    buildconfig_h.write_text(buildconfig_content, encoding="utf-8")
    print(f"[ARDUINO] Generated BuildConfig.h (EASYSD_DEBUG_SERIAL={mode_str})")


def arduino_compile(ctx: Context, debug_mode: bool = False, output_dir: Path = None, protocol_test: bool = False) -> None:
    """Compile Arduino sketch"""
    cli_exe = find_arduino_cli(ctx)

    # Generate BuildConfig.h first
    arduino_generate_buildconfig(ctx, debug_mode, protocol_test=protocol_test)

    print("\n" + "="*70)
    print("BUILDING ARDUINO SKETCH")
    print("="*70)
    print(f"  Sketch: {ctx.arduino_root}")
    print(f"  Board: {ARDUINO_FQBN}")
    print(f"  DEBUG_SERIAL: {'PROTOCOL_TEST' if protocol_test else ('ON' if debug_mode else 'OFF')}")
    print("="*70)

    compile_args = [
        "compile",
        "--fqbn", ARDUINO_FQBN,
        "--verbose",
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
    return size


def arduino_upload(ctx: Context, port: str, debug_mode: bool = False, protocol_test: bool = False) -> None:
    """Compile and upload Arduino sketch"""
    cli_exe = find_arduino_cli(ctx)

    # Generate BuildConfig.h first
    arduino_generate_buildconfig(ctx, debug_mode, protocol_test=protocol_test)

    print("\n" + "="*70)
    print("UPLOADING TO ARDUINO")
    print("="*70)
    print(f"  Sketch: {ctx.arduino_root}")
    print(f"  Board: {ARDUINO_FQBN}")
    print(f"  Port: {port}")
    print(f"  DEBUG_SERIAL: {'PROTOCOL_TEST' if protocol_test else ('ON' if debug_mode else 'OFF')}")
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


def find_bootloader_hex(ctx: Context) -> Path:
    """Find the ATmega328 bootloader hex in Arduino15 packages"""
    arduino15 = Path.home() / "AppData" / "Local" / "Arduino15"
    candidates = sorted(arduino15.glob(
        "packages/arduino/hardware/avr/*/bootloaders/optiboot/optiboot_atmega328.hex"
    ))
    if not candidates:
        raise SystemExit(
            "ERROR: Bootloader hex not found in Arduino15 packages.\n"
            "Run: python build.py arduino-setup"
        )
    return candidates[-1]


def arduino_upload_isp(ctx: Context, sck_period: int = 10, debug_mode: bool = False,
                       burn_bootloader: bool = False) -> None:
    """Compile and upload Arduino sketch via ISP programmer (USBTinyISP)"""
    output_dir = ctx.arduino_root / "build" / "arduino.avr.nano"
    size = arduino_compile(ctx, debug_mode=debug_mode, output_dir=output_dir)

    avrdude_exe, avrdude_conf = find_avrdude(ctx)

    hex_file = output_dir / "EasySD.ino.hex"
    if not hex_file.exists():
        raise SystemExit(f"ERROR: HEX file not found: {hex_file}")

    print("\n" + "="*70)
    print("UPLOADING VIA ISP (USBTinyISP)")
    print("="*70)
    print(f"  HEX:        {hex_file.name}")
    print(f"  Programmer: usbtinyisp")
    print(f"  SCK period: {sck_period} µs  ({1000 // sck_period} kHz)")
    print(f"  DEBUG_SERIAL: {'ON' if debug_mode else 'OFF'}")
    print(f"  Bootloader: {'YES (--optiboot, USB upload will work after)' if burn_bootloader else 'NO (default, no Optiboot)'}")
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

    if not burn_bootloader:
        # Default no-Optiboot mode: set hfuse BOOTRST=1 so CPU starts from $0000 (application)
        # not from the boot section ($7E00). Without this fuse change, the chip would
        # jump to $7E00 on reset even without a bootloader there → hang.
        # Restoring Optiboot later: run arduino-upload-isp --optiboot.
        print("\n" + "="*70)
        print("SETTING FUSE: BOOTRST=1 (application start at $0000, no Optiboot delay)")
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
                "-Uhfuse:w:0xDB:m",  # hfuse 0xDA→0xDB: flip BOOTRST bit (0→1 = start from $0000)
            ],
            cwd=ctx.repo_root
        )
        print("  NOTE: USB serial upload is now disabled.")
        print("  To restore: python build.py arduino-upload-isp --optiboot")

    if burn_bootloader:
        bootloader_hex = find_bootloader_hex(ctx)
        print("\n" + "="*70)
        print("BURNING BOOTLOADER (USBTinyISP)")
        print("="*70)
        print(f"  Bootloader: {bootloader_hex.name}")
        print(f"  (enabled with --optiboot)")
        print("="*70)

        run_cmd(
            [
                str(avrdude_exe),
                f"-C{avrdude_conf}",
                "-v",
                "-p", "atmega328p",
                "-c", "usbtiny",
                f"-B{sck_period}",
                "-D",  # no chip erase — preserve firmware
                "-Uhfuse:w:0xDA:m",  # BOOTSZ=01 (1024 words = 2KB section) per Arduino Nano boards.txt
                f"-Uflash:w:{bootloader_hex}:i",
                "-Ulock:w:0x0F:m",
            ],
            cwd=ctx.repo_root
        )

        print("\n" + "="*70)
        print("BOOTLOADER BURN COMPLETE! USB upload now available.")
        print("="*70)

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
  python build.py release              # C64 release + Arduino BuildConfig (serial OFF)
  python build.py debug-vice           # C64 VICE debug (mock data)
  python build.py debug-arduino        # C64 debug + Arduino BuildConfig (serial ON)
  python build.py multiload            # Build BOOT.PRG (multi-load launcher) only

  # Arduino operations
  python build.py arduino-setup        # One-time setup
  python build.py arduino-compile      # Compile (release mode)
  python build.py arduino-compile --debug  # Compile (debug mode - SERIAL ON)
    python build.py arduino-upload COM4               # Compile + Upload (USB)
    python build.py arduino-upload-isp                # Compile + Upload (ISP/USBTinyISP, no Optiboot)
    python build.py arduino-upload-isp --optiboot    # ISP upload + re-burn Optiboot bootloader
    python build.py arduino-upload-isp --isp-sck 10  # ISP with custom SCK period (µs)
    python build.py arduino-monitor COM4              # Serial monitor

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
            "core", "plugins", "multiload", "clean", "prebuild",
            # Arduino operations
            "arduino-setup", "arduino-compile", "arduino-upload", "arduino-upload-isp",
            "arduino-monitor", "arduino-list-ports", "arduino-clean",
            # Protocol echo test (Arduino-only, debug serial + protocol test flags)
            "protocol-test",
            # SD card deploy
            "sd-deploy",
            # Combined
            "all"
        ],
        help="Build target"
    )

    # Port/drive argument (COM port for Arduino, drive letter for sd-deploy)
    p.add_argument("port", nargs='?', default=None, help="COM port for Arduino upload/monitor (e.g. COM4), or drive letter for sd-deploy (e.g. D:)")

    # Options
    p.add_argument("--debug", action="store_true", help="Enable DEBUG mode (C64 mock data + Arduino SERIAL ON)")
    p.add_argument("--debug-break-after-load", action="store_true", help="Set DEBUG_BREAK_AFTER_LOAD=1")
    p.add_argument("--ml-debug-borders", action="store_true", help="MultiLoad: enable border-color stage markers (ML_DEBUG_BORDERS=1) for real-hardware hang diagnosis")
    p.add_argument("--skip-arduino", action="store_true", help="Skip Arduino/EPROM artifacts in C64 builds")
    p.add_argument("--menu-prg-name", default=None, help="Override menu PRG output name")
    p.add_argument("--baudrate", type=int, default=57600, help="Baudrate for serial monitor (default: 57600)")
    p.add_argument("--isp-sck", type=int, default=2, metavar="USEC",
                   help="ISP SCK period in µs for arduino-upload-isp (default: 2 = 500kHz, use 100 for blank/bricked chips)")
    p.add_argument("--optiboot", action="store_true",
                   help="After ISP upload, also burn the Optiboot bootloader so USB serial upload works again")
    p.add_argument("--no-bootloader", action="store_true",
                   help=argparse.SUPPRESS)

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

    if args.target == "arduino-upload-isp":
        if args.optiboot and args.no_bootloader:
            print("\nERROR: Use either --optiboot or --no-bootloader, not both")
            return 1
        arduino_upload_isp(ctx, sck_period=args.isp_sck, debug_mode=args.debug,
                           burn_bootloader=args.optiboot)
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

    if args.target == "sd-deploy":
        drive = args.port or "D:"
        sd_root = Path(drive) / ""
        plugins_dir = Path(drive) / "PLUGINS"
        if not plugins_dir.exists():
            print(f"ERROR: {plugins_dir} not found — is the SD card mounted as {drive}?")
            return 1
        copied = 0

        # easysd.prg → SD root (required: TransferMenu() loads menu from SD)
        menu_src = ctx.build_dir / "easysd.prg"
        if menu_src.exists():
            dst = Path(drive) / "EASYSD.PRG"
            shutil.copyfile(menu_src, dst)
            print(f"[SD-DEPLOY] {menu_src.name} -> {dst}")
            copied += 1
        else:
            print(f"WARNING: {menu_src} not found — run 'python build.py release' first")

        # build/plugins/*.prg → D:/PLUGINS/*.PRG
        src_dir = ctx.plugins_out_dir
        if not any(src_dir.glob("*.prg")):
            print(f"ERROR: No plugin PRG files in {src_dir} — run 'python build.py plugins' first")
            return 1
        print(f"[SD-DEPLOY] {src_dir} -> {plugins_dir}")
        for src in sorted(src_dir.glob("*.prg")):
            dst = plugins_dir / src.name.upper()
            shutil.copyfile(src, dst)
            print(f"  {src.name} -> {dst.name}")
            copied += 1
        print(f"[SD-DEPLOY] {copied} file(s) copied. OK")
        return 0

    if args.target == "protocol-test":
        # Compile (and optionally upload) with EASYSD_PROTOCOL_TEST flags.
        # Disables LOG_ENABLE_DIR/FILE to reclaim ~600B flash vs normal debug build.
        # Usage:
        #   python build.py protocol-test           # compile only
        #   python build.py protocol-test COM4      # compile + upload
        if args.port:
            arduino_upload(ctx, args.port, debug_mode=False, protocol_test=True)
        else:
            arduino_compile(ctx, debug_mode=False, protocol_test=True)
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

    menu_prg_name = args.menu_prg_name or ("easysd-debug.prg" if debug else "easysd.prg")

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

    if args.target == "multiload":
        ml_debug_borders = 1 if args.ml_debug_borders else 0
        build_multiload(ctx, debug=debug, debug_break=debug_break, ml_debug_borders=ml_debug_borders)
        return 0

    if args.target in ("release", "debug-vice", "debug-arduino"):
        clean(ctx)
        build_core(ctx, debug=debug, debug_break=debug_break, build_arduino=build_arduino, arduino_debug=arduino_debug, menu_prg_name=menu_prg_name)
        build_plugins(ctx, debug=debug, debug_break=debug_break, ensure_core_prereq=False)
        if args.target == "debug-vice":
            build_vice_tests(ctx)
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
        menu_name = "easysd-debug.prg" if c64_debug else "easysd.prg"

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
