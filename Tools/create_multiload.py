#!/usr/bin/env python3
"""create_multiload.py — Patch MultiLoad template PRG with game-specific first-part name.

Usage:
    python Tools/create_multiload.py LOADER
    python Tools/create_multiload.py ROBBIE

Output:
    EasySD/build/multiload/EASYLOAD.PRG

The template PRG (EasySD/build/plugins/bootplugin.prg) must already be built:
    python Tools/build.py multiload

The PRG file layout:
    Bytes 0-14  : BASIC SYS 2062 stub (easysd.obj, 15 bytes), load address $0801
    Byte  15    : start of plugin binary (assembled at $C000, JMP $C015)
    Byte  18    : ML_CONFIG_VERSION = 2  (= $C003 in C64 RAM)
    Byte  19    : ML_FIRST_PART_LEN      (= $C004)
    Bytes 20-35 : ML_FIRST_PART_NAME 16 bytes null-padded (= $C005-$C014)

    File offset = BAS_OBJ_SIZE (15) + ($C0xx - $C000).
"""

import sys
import os
import struct

TEMPLATE_REL = "EasySD/build/plugins/bootplugin.prg"
OUTPUT_DIR = "EasySD/build/multiload"
OUTPUT_FILE = "EASYLOAD.PRG"

# PRG file starts with 2-byte little-endian load address ($0801 — BASIC SYS stub).
PRG_LOAD_ADDR = 0x0801

# The BASIC SYS stub (easysd.obj) is always 15 bytes.
# Plugin binary starts immediately after it (= $C000 in C64 RAM).
BAS_OBJ_SIZE = 15

# File offsets of the config block:
#   $C003 = plugin offset 3 = file offset BAS_OBJ_SIZE + 3 = 18
#   $C004 = plugin offset 4 = file offset BAS_OBJ_SIZE + 4 = 19
#   $C005 = plugin offset 5 = file offset BAS_OBJ_SIZE + 5 = 20
OFFSET_VERSION   = BAS_OBJ_SIZE + 3   # = 18, ML_CONFIG_VERSION
OFFSET_LEN       = BAS_OBJ_SIZE + 4   # = 19, ML_FIRST_PART_LEN
OFFSET_NAME      = BAS_OBJ_SIZE + 5   # = 20, ML_FIRST_PART_NAME (16 bytes)
CONFIG_VERSION   = 2
MAX_NAME_LEN     = 16


def main():
    if len(sys.argv) != 2:
        print(f"Usage: python {sys.argv[0]} FIRST_PART_NAME")
        print("Example: python Tools/create_multiload.py LOADER")
        sys.exit(1)

    first_part = sys.argv[1].strip().upper()

    if not first_part:
        print("Error: first-part name cannot be empty.")
        sys.exit(1)

    if len(first_part) > MAX_NAME_LEN:
        print(f"Error: first-part name too long (max {MAX_NAME_LEN} chars, got {len(first_part)}).")
        sys.exit(1)

    # Resolve template path relative to repo root (or CWD)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    template_path = os.path.join(repo_root, TEMPLATE_REL)
    output_dir = os.path.join(repo_root, OUTPUT_DIR)
    output_path = os.path.join(output_dir, OUTPUT_FILE)

    # Check template exists
    if not os.path.exists(template_path):
        print(f"Error: template not found: {template_path}")
        print("Build it first with: python Tools/build.py multiload")
        sys.exit(1)

    # Read template
    with open(template_path, "rb") as f:
        data = bytearray(f.read())

    if len(data) < OFFSET_NAME + MAX_NAME_LEN:
        print(f"Error: template PRG too small ({len(data)} bytes, expected >= {OFFSET_NAME + MAX_NAME_LEN}).")
        sys.exit(1)

    # Verify load address
    load_lo, load_hi = data[0], data[1]
    load_addr = load_lo | (load_hi << 8)
    if load_addr != PRG_LOAD_ADDR:
        print(f"Warning: PRG load address is ${load_addr:04X}, expected ${PRG_LOAD_ADDR:04X}.")

    # Verify config version byte
    actual_version = data[OFFSET_VERSION]
    if actual_version != CONFIG_VERSION:
        print(f"Warning: ML_CONFIG_VERSION = {actual_version}, expected {CONFIG_VERSION}.")
        print("         The template may be from an older build. Proceeding anyway.")

    # Patch ML_FIRST_PART_LEN
    name_bytes = first_part.encode("ascii")
    data[OFFSET_LEN] = len(name_bytes)

    # Patch ML_FIRST_PART_NAME (16 bytes, null-padded)
    for i in range(MAX_NAME_LEN):
        data[OFFSET_NAME + i] = name_bytes[i] if i < len(name_bytes) else 0

    # Write output
    os.makedirs(output_dir, exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(data)

    print(f"[MULTILOAD] Patched: FIRST_PART = '{first_part}' ({len(name_bytes)} bytes)")
    print(f"[MULTILOAD] Output:  {output_path}")
    print(f"")
    print(f"  Copy {OUTPUT_FILE} to the game directory on your SD card:")
    print(f"    /MULTILOAD/{first_part}/{OUTPUT_FILE}")
    print(f"    /MULTILOAD/{first_part}/{first_part}.PRG")
    print(f"    /MULTILOAD/{first_part}/LEVEL1.PRG  (etc.)")


if __name__ == "__main__":
    main()
