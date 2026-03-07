# EasySD - Build Tools

## Overview

This folder contains the build and deployment tools for the EasySD project.

## Main Tools

### `build.py` - Main Build Script (v3.0.0)

**C64 code + Arduino artifact generation**

```bash
# Debug build for Arduino
python Tools/build.py debug-arduino

# Release build
python Tools/build.py release

# Debug build for VICE emulator
python Tools/build.py debug-vice

# Build only core or plugins
python Tools/build.py core
python Tools/build.py plugins

# Clean build artifacts
python Tools/build.py clean

# Arduino-specific commands
python Tools/build.py arduino-compile
python Tools/build.py arduino-upload COM4
python Tools/build.py arduino-upload-isp [--isp-sck USEC]
python Tools/build.py arduino-monitor COM4

# Skip Arduino artifact generation
python Tools/build.py release --skip-arduino

# First-time Arduino setup
python Tools/build.py arduino-setup
```

**NOTE:** On Windows, use `py` instead of `python` if needed (Python launcher).

**Options:**
- `debug-arduino` - Arduino debug build (serial output, more RAM usage)
- `debug-vice` - VICE emulator debug build (C64 only, mock data)
- `release` - Production build (optimized)
- `core` - Core files only (menu + loader)
- `plugins` - Plugins only
- `clean` - Delete build artifacts

**What it does:**
1. Compiles C64 assembly code (64tass)
2. Converts PETMATE menu export (`menu.asm` → `menu.bin`)
3. Generates Arduino header files (`FlashLib.h`, `BuildConfig.h`)
4. Compiles plugins

**Output:**
- `EasySD/build/easysd-debug.prg` - C64 program
- `EasySD/build/plugins/` - Plugin binaries
- `Arduino/EasySD/FlashLib.h` - Arduino header (generated)
- `Arduino/EasySD/BuildConfig.h` - Debug flag (generated)

---

## Workflow

### Standard Build (with Arduino IDE):

```bash
# 1. C64 + Arduino artifacts build
python Tools/build.py debug-arduino

# 2. Open Arduino IDE
# File → Open → Arduino/EasySD/EasySD.ino

# 3. Upload (Ctrl+U)
```

### Automated Build (arduino-cli):

```bash
# One-time setup
python Tools/build.py arduino-setup

# 1. C64 build + Arduino artifacts
python Tools/build.py debug-arduino

# 2. Arduino build + upload
python Tools/build.py arduino-upload COM4
```

### ISP Upload (blank chip):

```bash
python Tools/build.py arduino-upload-isp              # default speed
python Tools/build.py arduino-upload-isp --isp-sck 100  # 10kHz, blank chip
python Tools/build.py arduino-upload-isp --isp-sck 10   # 100kHz, with firmware
```

### Full Clean Build:

```bash
python Tools/build.py clean
python Tools/build.py debug-arduino
python Tools/build.py arduino-upload COM4
```

---

### `prepare_test_sd.py` - SD Card Test Preparation

Creates the required test file structure on an SD card for the Arduino self-test suite (`T` command).

```bash
python Tools/prepare_test_sd.py D:
```

**Creates:**
```
D:\
├── TESTDATA.BIN    (256 bytes, 0x00-0xFF pattern)
├── TESTFILE.TXT    (108 bytes)
├── BIGFILE.BIN     (2048 bytes, 0x00-0xFF x8)
└── TESTDIR/
    └── INNER.TXT   (17 bytes)
```

---

### `test_arduino_comm.py` - Arduino Serial Test Runner

Communicates with the Arduino firmware over USB serial (57600 baud) to run automated tests. Requires `pyserial` (`pip install pyserial`).

```bash
# Run self-test suite (sends 'T' command, parses results)
python Tools/test_arduino_comm.py COM4 --verbose

# Interactive serial terminal
python Tools/test_arduino_comm.py COM4 --interactive

# Directory navigation test only
python Tools/test_arduino_comm.py COM4 --test dir_nav
```

---

### `test_vice_menu.py` - VICE Automated C64 Menu Tests

Launches VICE (x64sc) in warp mode and verifies C64 menu behavior via the binary monitor protocol (TCP). Tests navigation, directory entry, and screen rendering. Requires VICE 3.9+.

```bash
# Run all 9 tests (requires prior debug-vice build)
python Tools/test_vice_menu.py

# Build first, then test
python Tools/test_vice_menu.py --build

# Verbose output (monitor protocol traffic)
python Tools/test_vice_menu.py --verbose

# Keep VICE open after tests for manual inspection
python Tools/test_vice_menu.py --keep-vice

# Custom VICE path
python Tools/test_vice_menu.py --vice-path "C:\VICE\bin\x64sc.exe"
```

**Tests:** INIT, NAV_DOWN, NAV_UP, NAV_WRAP, ENTER_DIR, GO_BACK, SCREEN_VERIFY, PRG_SELECT_ROOT, PRG_SELECT_SUBDIR

See `docs/testing/VICE_MENU_TEST.md` for full documentation.

---

### `cvd_convert.py` - CVD Video Converter

Converts MP4/AVI video files to the C64 CVD format used by CvdPlayer (Bad Apple!! decoder).

---

### `test_directory_navigation.py` / `test_file_io.py` - Legacy Test Scripts

Older manual/semi-automated test scripts. Superseded by `test_arduino_comm.py`.

---

## File Structure

```
Tools/
├── build.py                      # Main build script (v3.0.0)
├── README.md                     # This file
├── prepare_test_sd.py            # SD card test file preparation
├── test_arduino_comm.py          # PC-side Arduino serial test runner
├── test_vice_menu.py             # VICE automated C64 menu tests
├── cvd_convert.py                # CVD video converter
├── ComputeSidPlayer.prg          # SID computation helper (C64 binary)
├── test_directory_navigation.py  # Legacy directory navigation tests
├── test_file_io.py               # Legacy file I/O tests
└── archive/                      # Completed one-shot scripts (sprint tools, old docs)
```

---

## Troubleshooting

### `64tass not found`

Download 64tass and add it to your PATH:
https://sourceforge.net/projects/tass64/

### `arduino-cli not found`

Install: `winget install Arduino.ArduinoCLI`
Or see `docs/build/ARDUINO_CLI_SETUP.md` for detailed setup.

### `petcat not found`

Install VICE emulator and add its tools to PATH.

### `Port COM4 not found`

Check available ports: `python Tools/build.py arduino-upload --list-ports`
On Windows: Device Manager → Ports (COM & LPT)

---

## Related Documentation

- `docs/build/BUILD_SYSTEM.md` - Detailed build system documentation
- `docs/build/ARDUINO_CLI_SETUP.md` - Arduino CLI installation guide
- `docs/testing/VICE_MENU_TEST.md` - VICE automated menu test documentation

---

*Last updated: 2026-03-05*
*Build system version: v3.0.0*
