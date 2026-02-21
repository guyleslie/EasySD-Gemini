#!/usr/bin/env python3
"""
EasySD - SD Card Test File Preparation Script

Creates the required test file structure on an SD card for
the Arduino communication test suite.

On Windows, if the drive exists but has no filesystem (corrupted/raw),
the script will offer to format it as FAT32 before creating files.

Usage:
    python Tools/prepare_test_sd.py D:
    python Tools/prepare_test_sd.py D: --format
    python Tools/prepare_test_sd.py /media/sdcard
"""

import os
import sys
import platform
import subprocess

# ANSI colors
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

REQUIRED_FILES = {
    'TESTFILE.TXT': {
        'type': 'text',
        'content': 'EasySD Test File\n' * 6,
        'desc': 'Small text file (~108 bytes)',
    },
    'TESTDATA.BIN': {
        'type': 'binary',
        'content': bytes(range(256)),
        'desc': '256-byte pattern (0x00-0xFF)',
    },
    'BIGFILE.BIN': {
        'type': 'binary',
        'content': bytes(range(256)) * 8,
        'desc': '2048-byte pattern (0x00-0xFF x8)',
    },
}

REQUIRED_DIRS = {
    'TESTDIR': {
        'files': {
            'INNER.TXT': {
                'type': 'text',
                'content': 'Inner test file\n',
                'desc': 'Small file inside test directory',
            }
        }
    }
}


def create_file(path, spec):
    """Create a file from spec dict."""
    if spec['type'] == 'text':
        with open(path, 'w', encoding='ascii') as f:
            f.write(spec['content'])
    else:
        with open(path, 'wb') as f:
            f.write(spec['content'])
    size = os.path.getsize(path)
    print(f"  {GREEN}[CREATED]{RESET} {os.path.basename(path)} ({size} bytes) - {spec['desc']}")


def check_or_create_file(path, spec):
    """Check if file exists with correct size, create if not."""
    if os.path.exists(path):
        size = os.path.getsize(path)
        expected = len(spec['content'])
        if size == expected:
            print(f"  {GREEN}[OK]{RESET}      {os.path.basename(path)} ({size} bytes)")
            return
        else:
            print(f"  {YELLOW}[UPDATE]{RESET}  {os.path.basename(path)} (was {size}, expected {expected})")
    create_file(path, spec)


def format_windows_drive(drive_letter):
    """Format a Windows drive as FAT32 using PowerShell."""
    letter = drive_letter.rstrip(':\\/').upper()
    print(f"{YELLOW}[FORMAT]{RESET} Formatting {letter}: as FAT32...")
    try:
        result = subprocess.run(
            ['powershell', '-Command',
             f"Format-Volume -DriveLetter {letter} -FileSystem FAT32 "
             f"-NewFileSystemLabel EASYSD -Confirm:$false"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            print(f"{GREEN}[OK]{RESET}     Format complete (FAT32, label: EASYSD)")
            return True
        else:
            err = result.stderr.strip()
            print(f"{RED}[ERROR]{RESET} Format failed: {err}")
            return False
    except subprocess.TimeoutExpired:
        print(f"{RED}[ERROR]{RESET} Format timed out")
        return False


def check_drive_needs_format(sd_root):
    """On Windows, check if a removable drive exists but has no filesystem."""
    if platform.system() != 'Windows':
        return False

    letter = sd_root.rstrip(':\\/').upper()
    if len(letter) != 1 or not letter.isalpha():
        return False

    try:
        result = subprocess.run(
            ['powershell', '-Command',
             f"(Get-Volume -DriveLetter {letter}).Size"],
            capture_output=True, text=True, timeout=10
        )
        size_str = result.stdout.strip()
        if result.returncode == 0 and (not size_str or size_str == '0'):
            return True
    except (subprocess.TimeoutExpired, Exception):
        pass
    return False


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <sd_card_path>")
        print(f"  {sys.argv[0]} D:")
        print(f"  {sys.argv[0]} D: --format       (force format before prep)")
        print(f"  {sys.argv[0]} /media/sdcard")
        sys.exit(1)

    sd_root = sys.argv[1].rstrip('/\\')
    force_format = '--format' in sys.argv

    # Check if drive needs formatting (Windows only)
    if not os.path.isdir(sd_root):
        if check_drive_needs_format(sd_root):
            if force_format:
                do_format = True
            else:
                print(f"{YELLOW}[WARN]{RESET} Drive {sd_root} has no filesystem (corrupted/raw).")
                try:
                    answer = input(f"  Format as FAT32? [y/N] ").strip().lower()
                    do_format = answer in ('y', 'yes')
                except (EOFError, KeyboardInterrupt):
                    print()
                    do_format = False

            if do_format:
                if not format_windows_drive(sd_root):
                    sys.exit(1)
            else:
                print(f"{RED}[ERROR]{RESET} Cannot proceed without formatting.")
                sys.exit(1)
        else:
            print(f"{RED}[ERROR]{RESET} Path not found: {sd_root}")
            sys.exit(1)

    # --format flag: format even if drive is accessible
    if force_format and os.path.isdir(sd_root):
        if not format_windows_drive(sd_root):
            sys.exit(1)

    print(f"{BLUE}EasySD - SD Card Test Preparation{RESET}")
    print(f"Target: {sd_root}")
    print()

    # Create root-level test files
    print("Root files:")
    for name, spec in REQUIRED_FILES.items():
        check_or_create_file(os.path.join(sd_root, name), spec)

    # Create directories and their contents
    print("\nDirectories:")
    for dirname, dirspec in REQUIRED_DIRS.items():
        dirpath = os.path.join(sd_root, dirname)
        if os.path.isdir(dirpath):
            print(f"  {GREEN}[OK]{RESET}      {dirname}/")
        else:
            os.makedirs(dirpath, exist_ok=True)
            print(f"  {GREEN}[CREATED]{RESET} {dirname}/")

        for fname, fspec in dirspec.get('files', {}).items():
            check_or_create_file(os.path.join(dirpath, fname), fspec)

    print(f"\n{GREEN}SD card ready for testing.{RESET}")


if __name__ == "__main__":
    main()
