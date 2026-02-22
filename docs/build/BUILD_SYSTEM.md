# EasySD IRQHack64 Build System

**Version:** 2.2.0
**Last Updated:** 2025-12-26
**Sprint:** Sprint 7 (Build System Refactoring)

---

## Overview

The EasySD IRQHack64 build system is a unified Python-based build tool that handles both C64 (6502 assembly) and Arduino (AVR C++) compilation. The system supports multiple build targets, artifact management, and automated testing.

**Key Features:**
- Unified build script for C64 + Arduino
- Artifact separation (build artifacts vs source code)
- Staleness detection for generated headers
- Intent tracking (build metadata in generated files)
- VICE-only optimization (skip unnecessary Arduino builds)
- Serial monitor integration
- Arduino CLI integration

---

## Quick Start

### Prerequisites

**C64 Build Tools:**
- `64tass` (64tass Turbo Assembler) - for C64 assembly
- `petcat` (VICE petcat) - for BASIC header conversion

**Arduino Build Tools:**
- `arduino-cli` - Arduino command-line interface

**Python:**
- Python 3.7+ with `pathlib`, `subprocess`, `dataclasses`

### Basic Usage

```bash
# Navigate to Tools directory
cd "C:\EasySD Gemini\Tools"

# Clean previous builds
python build.py clean

# Build release version (C64 + Arduino)
python build.py release

# Build debug version for VICE emulator only
python build.py debug-vice

# Build debug version with Arduino serial debug
python build.py debug-arduino

# Compile Arduino firmware only
python build.py arduino-compile

# Upload firmware to Arduino
python build.py arduino-upload COM4

# Serial monitor
python build.py arduino-monitor COM4
```

---

## Build Targets

### C64 Targets

#### `release`
**Description:** Production release build
**C64 DEBUG:** OFF (0)
**Arduino DEBUG_SERIAL:** OFF
**Output:**
- `build/irqhack64.prg` - Main C64 cartridge binary
- `build/plugins/*.prg` - Plugin binaries
- `build/artifacts/FlashLib.h` - Arduino header with C64 binary data
- `build/artifacts/BuildConfig.h` - Arduino configuration header

**Use Case:** Final production firmware for cartridge deployment

#### `debug-vice`
**Description:** Debug build for VICE emulator testing
**C64 DEBUG:** ON (1)
**Arduino DEBUG_SERIAL:** N/A
**Output:**
- `build/irqhack64-debug.prg` - C64 debug binary with symbols
- `build/plugins/*.prg` - Plugin binaries
- `build/symbol/IrqLoaderMenuNew.vs` - VICE-format labels (for binary monitor / `test_vice_menu.py`)
- **NO Arduino artifacts** (optimization: saves 66KB + 9 operations)

**Use Case:** VICE emulator testing, C64 development, automated VICE menu tests

#### `debug-arduino`
**Description:** Debug build with Arduino serial debugging
**C64 DEBUG:** ON (1)
**Arduino DEBUG_SERIAL:** ON
**Output:**
- `build/irqhack64-debug.prg` - C64 debug binary
- `build/plugins/*.prg` - Plugin binaries
- `build/artifacts/FlashLib.h` - Arduino header
- `build/artifacts/BuildConfig.h` - with `#define EASYSD_DEBUG_SERIAL`

**Use Case:** Arduino firmware debugging, serial monitor output

#### `core`
**Description:** Build only core C64 binary (no plugins)
**Output:**
- `build/irqhack64.prg` or `build/irqhack64-debug.prg`
- `build/artifacts/FlashLib.h`
- `build/artifacts/BuildConfig.h`

**Use Case:** Quick iteration during core development

#### `plugins`
**Description:** Build only plugins (requires existing core build)
**Output:**
- `build/plugins/*.prg` - All plugin binaries

**Use Case:** Plugin development without rebuilding core

### Arduino Targets

#### `arduino-compile`
**Description:** Compile Arduino firmware
**Flags:**
- `--debug` - Enable serial debugging (`#define EASYSD_DEBUG_SERIAL`)

**Process:**
1. Check FlashLib.h freshness (warns if stale)
2. Generate BuildConfig.h with intent tracking
3. Copy artifacts from `build/artifacts/` to `Arduino/IRQHack64/`
4. Compile using arduino-cli

**Output:**
- Arduino HEX file ready for upload

#### `arduino-upload`
**Description:** Compile and upload firmware to Arduino
**Parameters:**
- `port` - COM port (e.g., COM4)
- `--debug` - Enable serial debugging

**Process:**
1. Same as `arduino-compile`
2. Upload to specified COM port via arduino-cli

**Example:**
```bash
python build.py arduino-upload COM4 --debug
```

#### `arduino-monitor`
**Description:** Serial monitor for debugging
**Parameters:**
- `port` - COM port (e.g., COM4)
- `--baudrate` - Serial baudrate (default: 57600)

**Example:**
```bash
python build.py arduino-monitor COM4
```

### Utility Targets

#### `clean`
**Description:** Remove all build artifacts
**Deletes:**
- `build/*.prg`
- `build/plugins/*.prg`
- `build/symbol/*.txt`
- `build/listing/*.txt`
- `build/artifacts/*`
- All intermediate binaries

#### `prebuild`
**Description:** Validate build environment
**Checks:**
- 64tass availability
- petcat availability
- Required directories

#### `arduino-setup`
**Description:** Install Arduino dependencies
**Installs:**
- Arduino AVR core
- Required libraries (SdFat, ByteQueue, etc.)

#### `arduino-list-ports`
**Description:** List available COM ports for Arduino upload

#### `arduino-clean`
**Description:** Clean Arduino build cache

#### `all`
**Description:** Full build workflow
**Process:**
1. Clean previous builds
2. Build C64 core + plugins (release mode)
3. Compile Arduino firmware (release mode)

---

## Build System Architecture

### Directory Structure

```
C:\EasySD Gemini\
├── IRQHack64/                  # C64 source code
│   ├── Loader/                 # Cartridge loader
│   ├── Menus/                  # Menu systems
│   ├── Plugins/                # File type plugins
│   └── build/                  # Build output
│       ├── irqhack64.prg       # Main C64 binary
│       ├── plugins/            # Plugin binaries
│       ├── symbol/             # Debug symbols (.txt labels + .vs VICE labels)
│       ├── listing/            # Assembly listings
│       └── artifacts/          # Build artifacts (Sprint 7)
│           ├── FlashLib.h      # C64 binary as Arduino header
│           ├── BuildConfig.h   # Arduino config with intent tracking
│           └── IRQLoaderRom.bin # EPROM loader binary
├── Arduino/IRQHack64/          # Arduino source code (workspace)
│   ├── IRQHack64.ino           # Main sketch
│   ├── CartApi.cpp/h           # C64 cartridge API
│   ├── CartInterface.cpp/h     # Low-level interface
│   ├── DirFunction.cpp/h       # Directory navigation
│   ├── FlashLib.h              # (copied from build/artifacts/)
│   └── BuildConfig.h           # (copied from build/artifacts/)
└── Tools/
    ├── build.py                # Main build script (v2.2.0)
    ├── test_*.py               # Test suites
    └── README.md               # Tools documentation
```

### Artifact Flow (Sprint 7)

**Phase 1: C64 Build → Artifact Generation**
```
C64 Sources (.s, .65s)
    ↓ 64tass assembler (run 1: --labels → .txt format)
    ↓ 64tass assembler (run 2: --vice-labels --labels → .vs VICE format)
C64 Binaries (.prg, .bin)
    ↓ bin2ardh conversion
build/artifacts/FlashLib.h      # C64 data embedded in C header
build/artifacts/BuildConfig.h   # Arduino config with metadata
build/symbol/*.txt              # Standard label format (NAME = $ADDR)
build/symbol/*.vs               # VICE label format (al ADDR .NAME)
```

**Note:** 64tass requires two separate invocations because `--vice-labels` is a flag
that modifies the `--labels` output format (not a separate filename argument).
The second run outputs the binary to `os.devnull` — only the `.vs` label file matters.

**Phase 2: Artifact Copy → Arduino Workspace**
```
build/artifacts/FlashLib.h
build/artifacts/BuildConfig.h
    ↓ copy_arduino_artifacts()
Arduino/IRQHack64/FlashLib.h
Arduino/IRQHack64/BuildConfig.h
```

**Phase 3: Arduino Compilation**
```
Arduino Sources (.ino, .cpp)
+ FlashLib.h (C64 binary data)
+ BuildConfig.h (debug flags)
    ↓ arduino-cli compile
Arduino HEX (firmware binary)
```

**Why This Design?**
- **Separation of Concerns:** Build artifacts separated from source code
- **VICE Optimization:** VICE builds skip Arduino artifact generation (66KB saved)
- **Intent Tracking:** BuildConfig.h includes metadata (target name + timestamp)
- **Staleness Detection:** Warns if FlashLib.h is older than C64 sources

---

## Build Configuration

### Context Dataclass

The build system uses a frozen dataclass for configuration:

```python
@dataclass(frozen=True)
class Context:
    repo_root: Path           # C:\EasySD Gemini
    irq_root: Path            # C:\EasySD Gemini\IRQHack64
    arduino_root: Path        # C:\EasySD Gemini\Arduino\IRQHack64
    tools_dir: Path           # C:\EasySD Gemini\Tools
    build_dir: Path           # C:\EasySD Gemini\IRQHack64\build
    sym_dir: Path             # build/symbol
    lst_dir: Path             # build/listing
    plugins_out_dir: Path     # build/plugins
    artifacts_dir: Path       # build/artifacts (Sprint 7)
```

### BuildConfig.h Intent Tracking

**Format:**
```c
// Generated by: <target_name>
// Date: <timestamp>
// EASYSD_DEBUG_SERIAL enabled/disabled (debug/release build)
#define EASYSD_DEBUG_SERIAL  // (if debug mode)
```

**Example (debug-arduino):**
```c
// Generated by: irqhack64-debug
// Date: 2025-12-26 22:34:56
// EASYSD_DEBUG_SERIAL enabled (debug build)
#define EASYSD_DEBUG_SERIAL
```

**Example (release):**
```c
// Generated by: irqhack64
// Date: 2025-12-26 22:28:04
// EASYSD_DEBUG_SERIAL disabled (release build)
```

**Benefits:**
- Traceability: Know which build target generated the file
- Debugging: Timestamp helps identify stale builds
- Clarity: Explicit debug mode indication

---

## Advanced Features

### Staleness Detection

**Purpose:** Prevent Arduino compilation with outdated FlashLib.h

**How It Works:**
1. Before `arduino-compile` or `arduino-upload`, check timestamps:
   - `build/artifacts/FlashLib.h` modification time
   - vs C64 source files: `IRQLoader.65s`, `LoaderStub.65s`, `Warning.s`, `avrinclude*.txt`
2. If any C64 source is newer than FlashLib.h → **WARN**
3. User prompt:
   ```
   ======================================================================
   WARNING: FlashLib.h MAY BE OUTDATED!
   ======================================================================
   C64 source files have been modified since FlashLib.h was generated.
   You should rebuild C64 artifacts first:
     python build.py release
   ======================================================================
   Continue anyway? (y/N):
   ```
4. User choice:
   - `N` → Abort build (exit code 1)
   - `y` → Continue with stale FlashLib.h (user's responsibility)

**Bypass Staleness Check:**
```bash
# Rebuild C64 artifacts first
python build.py release
# Now FlashLib.h is fresh
python build.py arduino-compile
```

### VICE-Only Build Optimization

**Problem (Pre-Sprint 7):**
- `debug-vice` target generated 66KB Arduino artifacts (FlashLib.h + IRQLoaderRom.bin)
- VICE emulator never uses Arduino artifacts
- Waste: 66KB disk space + 9 unnecessary operations per build

**Solution (Sprint 7):**
- `debug-vice` removed from `build_arduino` condition
- Only `release`, `debug-arduino`, `core` generate Arduino artifacts
- VICE builds complete faster, cleaner

**Code:**
```python
# Line 898 (build.py)
build_arduino = (args.target in ("release", "debug-arduino", "core")) and (not args.skip_arduino)
# NOTE: debug-vice does NOT generate Arduino artifacts (cleaner, faster build)
```

**Metrics:**
- **Before:** `debug-vice` → 66KB waste
- **After:** `debug-vice` → 0 bytes waste ✅

### Skip Arduino Build Flag

**Usage:**
```bash
# Build C64 only, skip Arduino artifact generation
python build.py release --skip-arduino
```

**Use Cases:**
- C64-only development
- CI/CD C64 validation pipeline
- Quick iteration without Arduino recompilation

---

## Arduino Configuration

### Board Configuration

**Board:** Arduino Nano
**FQBN:** `arduino:avr:nano:cpu=atmega328old`
**CPU:** ATmega328P (Old Bootloader)

**Change Board:**
Edit `ARDUINO_FQBN` constant in `build.py`:
```python
ARDUINO_FQBN = "arduino:avr:nano:cpu=atmega328old"
```

### Serial Monitor Settings

**Default Baudrate:** 57600
**Change Baudrate:**
```bash
python build.py arduino-monitor COM4 --baudrate 115200
```

**Why 57600?**
- Compatible with Arduino Nano default
- Reliable for debug output
- Matches firmware initialization

### Required Libraries

**Automatically Installed via `arduino-setup`:**
- **SdFat 2.3.0** - SD card file system
- **SPI** - SPI communication (built-in)
- **EEPROM** - EEPROM storage (built-in)
- **ByteQueue** - Custom byte buffer library

**Manual Installation:**
```bash
arduino-cli lib install SdFat
# ByteQueue: Copy to ~/Documents/Arduino/libraries/
```

---

## Debug Features

### Serial Debug Output

**Enable:** Build with `--debug` flag or use `debug-arduino` target

**Debug Messages:**
```c
#ifdef EASYSD_DEBUG_SERIAL
  Serial.println(F("[DIR] Changed to ROOT"));
  Serial.print(F("RAM: ")); Serial.println(freeMemory());
#endif
```

**Log Categories:**
- `[SD]` - SD card operations
- `[DIR]` - Directory navigation
- `[FILE]` - File operations
- `[ERR]` - Error messages
- `[MEM]` - Memory status

**Example Output:**
```
================================
 EasySD IRQHack64 v2.1.0
 SdFat 2.3.0 | Arduino Nano
================================

SD OK
RAM: 459
Type 'h' for help

[DIR] Changed to ROOT
[DIR] Prep: / (3 items, 411 bytes free)
```

### Memory Monitoring

**Free RAM Reporting:**
- Reports free SRAM after initialization
- Typical: ~450-500 bytes free (ATmega328P has 2KB SRAM)
- Warning if <200 bytes (potential stack overflow risk)

**Monitor Command:**
```bash
python build.py arduino-monitor COM4
```

---

## Troubleshooting

### Common Issues

#### "FlashLib.h not found"
**Cause:** Arduino artifacts not generated
**Solution:**
```bash
python build.py release  # Generate artifacts first
python build.py arduino-compile
```

#### "FlashLib.h is NEWER than sources" warning
**Cause:** C64 sources modified after last build
**Solution:**
```bash
python build.py release  # Rebuild C64 artifacts
python build.py arduino-compile
```

#### "arduino-cli not found"
**Cause:** Arduino CLI not installed or not in PATH
**Solution:**
1. Install Arduino CLI: https://arduino.github.io/arduino-cli/
2. Add to PATH
3. Run `python build.py arduino-setup`

#### "64tass not found"
**Cause:** 64tass assembler not installed
**Solution:**
1. Download 64tass: http://tass64.sourceforge.net/
2. Extract to `E:/Apps/64tass-1.59.3120/` (or update path in build.py)
3. Update `resolve_tool()` paths if needed

#### "Port COM4 not available"
**Cause:** Arduino not connected or wrong port
**Solution:**
```bash
python build.py arduino-list-ports  # List available ports
python build.py arduino-upload COM3  # Try different port
```

### Build Script Errors

#### "Context has no attribute 'artifacts_dir'"
**Cause:** Using old build.py (pre-Sprint 7)
**Solution:** Ensure you're using `build.py` version 2.2.0+

#### "Permission denied: FlashLib.h"
**Cause:** File locked by Arduino IDE or editor
**Solution:** Close Arduino IDE, then rebuild

---

## Build Script API

### Key Functions

#### `make_context() -> Context`
**Description:** Create build context with all paths
**Returns:** Frozen Context dataclass

#### `build_core(ctx, debug, debug_break, build_arduino, arduino_debug, menu_prg_name)`
**Description:** Build C64 core binary + generate Arduino artifacts
**Parameters:**
- `debug` - C64 debug symbols (0/1)
- `debug_break` - Break after load (0/1)
- `build_arduino` - Generate Arduino artifacts (True/False)
- `arduino_debug` - Enable EASYSD_DEBUG_SERIAL (0/1)
- `menu_prg_name` - Output PRG filename

**Artifacts Generated (if build_arduino=True):**
- `build/artifacts/FlashLib.h`
- `build/artifacts/BuildConfig.h`
- `build/IRQLoaderRom.bin`

#### `build_plugins(ctx, debug, debug_break)`
**Description:** Build all C64 plugins
**Output:** `build/plugins/*.prg`

#### `generate_buildconfig_h(ctx, target_name, debug_mode) -> Path`
**Description:** Generate BuildConfig.h with intent tracking
**Parameters:**
- `target_name` - Build target identifier (e.g., "irqhack64", "arduino-compile")
- `debug_mode` - Enable EASYSD_DEBUG_SERIAL (True/False)

**Returns:** Path to generated file (`build/artifacts/BuildConfig.h`)

#### `check_flashlib_freshness(ctx, interactive=True) -> bool`
**Description:** Check if FlashLib.h is fresher than C64 sources
**Parameters:**
- `interactive` - Prompt user on stale detection (True/False)

**Returns:**
- `True` - OK to continue (FlashLib.h is fresh or user approved)
- `False` - Abort build (FlashLib.h is stale and user declined)

#### `copy_arduino_artifacts(ctx)`
**Description:** Copy artifacts from `build/artifacts/` to `Arduino/IRQHack64/`
**Copies:**
- FlashLib.h
- BuildConfig.h

#### `arduino_compile(ctx, debug_mode=False)`
**Description:** Compile Arduino firmware
**Process:**
1. Check FlashLib.h freshness
2. Generate BuildConfig.h
3. Copy artifacts to workspace
4. Run arduino-cli compile

#### `arduino_upload(ctx, port, debug_mode=False)`
**Description:** Compile and upload Arduino firmware
**Process:**
1. Same as `arduino_compile()`
2. Upload to specified COM port

---

## Version History

### v2.2.0 (Sprint 7 - 2025-12-26)
**Changes:**
- ✅ Artifact separation (`build/artifacts/`)
- ✅ VICE-only build optimization (66KB saved)
- ✅ FlashLib.h staleness detection
- ✅ BuildConfig.h intent tracking
- ✅ Renamed `build_new.py` → `build.py`
- ✅ Deleted obsolete build scripts

**Migration:**
- Old `build.py` → Deleted
- Old `build_old.py` → Deleted
- Old `arduino_build_upload.py` → Deleted
- Batch scripts → Deleted

### v2.1.0 (Sprint 6)
**Changes:**
- Serial monitor UI/UX improvements
- Structured logging system
- Error handling standardization
- Memory status display

### v2.0.0 (Sprint 5)
**Changes:**
- SdFat 2.x migration
- Unified build system (C64 + Arduino)

---

## Support

**Documentation:**
- `SPRINT7_COMPLETION.md` - Sprint 7 implementation details
- `SPRINT6_COMPLETION.md` - Sprint 6 UX improvements
- `CHANGELOG_UNIFIED.md` - Full version history
- `docs/testing/VICE_MENU_TEST.md` - VICE automated test documentation

**Build System Issues:**
- Check `Tools/build.py` version: Should be v2.2.0+
- Verify prerequisites: 64tass, petcat, arduino-cli
- Review `SPRINT7_COMPLETION.md` for known issues

**Hardware Issues:**
- Arduino: Verify COM port with `arduino-list-ports`
- SD Card: Format FAT32, check compatibility
- C64: Test VICE emulator first with `debug-vice` build

---

**Build System Version:** 2.2.0
**Last Updated:** 2025-12-26
**Maintainer:** EasySD IRQHack64 Project
