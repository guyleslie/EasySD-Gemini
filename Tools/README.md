# EasySD / IRQHack64 - Build Tools

## Overview

This folder contains the build and deployment tools for the EasySD/IRQHack64 project.

## Main Tools

### `build.py` - Main Build Script

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
2. Generates Arduino header files (FlashLib.h, BuildConfig.h)
3. Creates EPROM loader files
4. Compiles plugins

**Output:**
- `IRQHack64/build/irqhack64-debug.prg` - C64 program
- `Arduino/IRQHack64/FlashLib.h` - Arduino header (generated)
- `Arduino/IRQHack64/BuildConfig.h` - Debug flag (generated)

---

## Workflow

### Standard Build (with Arduino IDE):

```bash
# 1. C64 + Arduino artifacts build
python Tools/build.py debug-arduino

# 2. Open Arduino IDE
# File → Open → Arduino/IRQHack64/IRQHack64.ino

# 3. Upload (Ctrl+U)
```

### Automated Build (arduino-cli):

```bash
# One-time setup
python Tools/build.py arduino-setup

# 1. C64 build + Arduino artifacts
python Tools/build.py debug-arduino

# 2. Arduino build + upload
python Tools/build.py arduino-upload COM3
```

### Full Clean Build:

```bash
python Tools/build.py clean
python Tools/build.py debug-arduino
python Tools/build.py arduino-upload COM3
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
# Run all 7 tests (requires prior debug-vice build)
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

**Tests:** INIT, NAV_DOWN, NAV_UP, NAV_WRAP, ENTER_DIR, GO_BACK, SCREEN_VERIFY

See `docs/testing/VICE_MENU_TEST.md` for full documentation.

---

## File Structure

```
Tools/
├── build.py                    # Main build script (v2.2.0)
├── README.md                   # This file
├── prepare_test_sd.py          # SD card test file preparation
├── test_arduino_comm.py        # PC-side Arduino serial test runner
├── test_vice_menu.py           # VICE automated C64 menu tests
├── test_directory_navigation.py # Directory navigation tests (legacy)
└── test_file_io.py             # File I/O tests (legacy)

IRQHack64/
├── build/                      # Build output (generated)
│   ├── irqhack64-debug.prg    # C64 program
│   ├── plugins/               # Plugin binaries
│   └── symbol/                # Debug symbols (.txt + .vs VICE labels)
└── ...                        # Assembly source files

Arduino/
├── IRQHack64/                 # Arduino sketch
│   ├── IRQHack64.ino         # Main sketch
│   ├── FlashLib.h            # Generated (build.py)
│   ├── BuildConfig.h         # Generated (build.py)
│   ├── CartApi.cpp           # API implementation
│   └── ...
└── libraries/                 # Project-specific libraries
    ├── SdFat/                # SD card library (v2.3.0)
    └── ByteQueue/            # Queue implementation
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

### `Port COM3 not found`

Check available ports: `python Tools/build.py arduino-upload --list-ports`
On Windows: Device Manager → Ports (COM & LPT)

---

## Related Documentation

- `docs/build/BUILD_SYSTEM.md` - Detailed build system documentation
- `docs/build/ARDUINO_CLI_SETUP.md` - Arduino CLI installation guide
- `docs/testing/VICE_MENU_TEST.md` - VICE automated menu test documentation

---

*Last updated: 2025-12-26*
*Build system version: v2.2.0*
