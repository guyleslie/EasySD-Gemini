#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Complete Arduino Build & Upload Tool (IDE-free)
Uses arduino-cli for compilation and upload

Installation:
1. Download arduino-cli: https://arduino.github.io/arduino-cli/latest/installation/
2. Extract arduino-cli.exe to Tools/ folder (or add to PATH)
3. Run: python arduino_build_upload.py setup  (first time only)
4. Run: python arduino_build_upload.py upload COM3

Commands:
  setup             - Install Arduino Nano board support and libraries (one time)
  build             - Compile the sketch only
  upload [PORT]     - Compile and upload to Arduino Nano
  monitor [PORT]    - Open serial monitor (57600 baud default)
  list-ports        - List available COM ports
"""

import shutil
import subprocess
import sys
from pathlib import Path


def find_arduino_cli(tools_dir: Path) -> Path:
    """Find or download arduino-cli"""
    # Check common installation locations
    candidates = [
        tools_dir / "arduino-cli.exe",  # Tools directory
        Path("C:/Program Files/Arduino CLI/arduino-cli.exe"),  # Standard install
        Path("C:/Program Files (x86)/Arduino CLI/arduino-cli.exe"),  # x86 install
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
    sys.exit(1)


def run_cli(cli_exe: Path, args: list, check=True) -> subprocess.CompletedProcess:
    """Run arduino-cli command"""
    cmd = [str(cli_exe)] + args
    print(f"\n> {' '.join(cmd)}")
    return subprocess.run(cmd, check=check)


def setup_arduino_cli(cli_exe: Path, repo_root: Path):
    """Setup arduino-cli: install board support and libraries"""
    print("\n" + "="*70)
    print("ARDUINO-CLI SETUP")
    print("="*70)

    # Update core index
    print("\n[1/5] Updating board index...")
    run_cli(cli_exe, ["core", "update-index"])

    # Install Arduino AVR boards
    print("\n[2/5] Installing Arduino AVR boards...")
    run_cli(cli_exe, ["core", "install", "arduino:avr"])

    # Install SdFat library (use project version)
    print("\n[3/5] Installing libraries...")

    # Install ByteQueue from project
    bytequeue_src = repo_root / "Arduino" / "libraries" / "ByteQueue"
    if bytequeue_src.exists():
        print(f"  Linking ByteQueue from project...")
        # arduino-cli doesn't support symlinks well, so we'll rely on sketch local libraries

    # Install SdFat - try project version first
    sdfat_src = repo_root / "Arduino" / "libraries" / "SdFat" / "SdFat"
    if sdfat_src.exists():
        print(f"  Using project SdFat library")

    # Install from library manager as fallback
    run_cli(cli_exe, ["lib", "install", "SdFat"], check=False)

    print("\n[4/5] Listing installed libraries...")
    run_cli(cli_exe, ["lib", "list"])

    print("\n[5/5] Listing installed boards...")
    run_cli(cli_exe, ["board", "listall", "nano"])

    print("\n" + "="*70)
    print("SETUP COMPLETE!")
    print("="*70)
    print("\nNext: python arduino_build_upload.py upload COM3")


def build_sketch(cli_exe: Path, sketch_dir: Path, fqbn: str):
    """Compile Arduino sketch"""
    print("\n" + "="*70)
    print("BUILDING SKETCH")
    print("="*70)
    print(f"  Sketch: {sketch_dir}")
    print(f"  Board: {fqbn}")
    print("="*70)

    run_cli(cli_exe, [
        "compile",
        "--fqbn", fqbn,
        "--verbose",
        str(sketch_dir)
    ])

    print("\n" + "="*70)
    print("BUILD COMPLETE!")
    print("="*70)


def upload_sketch(cli_exe: Path, sketch_dir: Path, fqbn: str, port: str):
    """Compile and upload Arduino sketch"""
    print("\n" + "="*70)
    print("UPLOADING TO ARDUINO")
    print("="*70)
    print(f"  Sketch: {sketch_dir}")
    print(f"  Board: {fqbn}")
    print(f"  Port: {port}")
    print("="*70)

    run_cli(cli_exe, [
        "compile",
        "--upload",
        "--fqbn", fqbn,
        "--port", port,
        "--verbose",
        str(sketch_dir)
    ])

    print("\n" + "="*70)
    print("UPLOAD COMPLETE!")
    print("="*70)
    print("\nOpen Serial Monitor @ 57600 baud to see output")


def list_ports(cli_exe: Path):
    """List available COM ports"""
    print("\nAvailable ports:")
    run_cli(cli_exe, ["board", "list"])


def monitor_serial(cli_exe: Path, port: str, baudrate: int = 57600):
    """Open serial monitor"""
    print("\n" + "="*70)
    print("SERIAL MONITOR")
    print("="*70)
    print(f"  Port: {port}")
    print(f"  Baudrate: {baudrate}")
    print("="*70)
    print("\nPress Ctrl+C to exit\n")

    run_cli(cli_exe, [
        "monitor",
        "--port", port,
        "--config", f"baudrate={baudrate}",
        "--raw"
    ], check=False)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    command = sys.argv[1]

    # Find repository root
    script_dir = Path(__file__).parent.resolve()
    repo_root = script_dir.parent
    tools_dir = script_dir
    sketch_dir = repo_root / "Arduino" / "IRQHack64"

    # Find arduino-cli
    cli_exe = find_arduino_cli(tools_dir)
    print(f"Using arduino-cli: {cli_exe}")

    # FQBN for Arduino Nano (ATmega328P, Old Bootloader)
    fqbn = "arduino:avr:nano:cpu=atmega328old"

    if command == "setup":
        setup_arduino_cli(cli_exe, repo_root)

    elif command == "build":
        build_sketch(cli_exe, sketch_dir, fqbn)

    elif command == "upload":
        if len(sys.argv) < 3:
            print("\nERROR: COM port required")
            list_ports(cli_exe)
            print("\nUsage: python arduino_build_upload.py upload COM3")
            sys.exit(1)

        port = sys.argv[2]
        upload_sketch(cli_exe, sketch_dir, fqbn, port)

    elif command == "list-ports":
        list_ports(cli_exe)

    elif command == "monitor":
        if len(sys.argv) < 3:
            print("\nERROR: COM port required")
            list_ports(cli_exe)
            print("\nUsage: python arduino_build_upload.py monitor COM3")
            sys.exit(1)

        port = sys.argv[2]
        baudrate = int(sys.argv[3]) if len(sys.argv) > 3 else 57600
        monitor_serial(cli_exe, port, baudrate)

    else:
        print(f"ERROR: Unknown command: {command}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
