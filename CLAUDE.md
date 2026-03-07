# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Safety Rules (CRITICAL)

This is a **private repository** without branch protection (free GitHub plan limitation). Extra care required:

- **NEVER `git push --force`** to main
- **NEVER `git reset --hard`** on committed work
- **NEVER `git branch -D main`**
- **Always commit individually** per logical change, then push
- **Never amend published commits** — create new commits instead

## Project Summary

EasySD is an SD card interface for the Commodore 64, combining an Arduino Nano/Pro Mini "file server" with a C64-side menu and plugin system. Users browse and load files from FAT-formatted SD cards through a cartridge.

- **C64 side:** 6502 assembly (64tass assembler)
- **Arduino side:** C++ (ATmega328P, SdFat 2.x library)
- **Build system:** Python 3.x (`Tools/build.py`)
- **Communication:** Custom software serial (C64→Arduino) + NMI-driven byte transfer (Arduino→C64)

## Build Commands

All commands run from the repository root.

```bash
# Full release build (C64 + Arduino artifacts)
python Tools/build.py release

# Debug for VICE emulator (C64 only, mock data, no Arduino artifacts)
python Tools/build.py debug-vice

# Debug with Arduino serial output (recommended for full-system debug)
python Tools/build.py debug-arduino

# Build only core or only plugins
python Tools/build.py core
python Tools/build.py plugins

# Clean all build artifacts
python Tools/build.py clean

# Arduino-specific commands
python Tools/build.py arduino-compile
python Tools/build.py arduino-upload COM4
python Tools/build.py arduino-monitor COM4

# Skip Arduino artifact generation during C64 builds
python Tools/build.py release --skip-arduino
```

**Prerequisites:** `64tass` and `petcat` (VICE) in PATH, `arduino-cli` installed, Python 3.7+.

**First-time Arduino setup:** `python Tools/build.py arduino-setup`

## Architecture

### Dual-System Design

**Arduino firmware** (`Arduino/EasySD/`): Manages SD card, FAT filesystem, directory navigation, file streaming, TAP conversion. Entry point is `EasySD.ino`, command routing in `CartApi.cpp`, directory logic in `DirFunction.cpp`.

**C64 software** (`EasySD/`): Cartridge ROM with communication library (`Loader/`), main file browser menu (`Menus/EasySD/IrqLoaderMenuNew.s`), and file-type plugins (`Plugins/`).

### Build Artifact Flow

PETMATE `menu.asm` → `convert_petmate_asm()` → `menu.bin` → C64 assembly (`.binary "menu.bin"`) → 64tass → `.prg` binaries → `bin2ardh` → `build/artifacts/FlashLib.h` → copied to `Arduino/EasySD/` → `arduino-cli compile` → firmware HEX. The `debug-vice` target skips Arduino artifact generation entirely.

### C64 Include Hierarchy (strict linear chain, no include guards in 64tass)

```
CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc / IRQHack.inc
```

Plugins include the highest-level wrapper they need. For most plugins: `CartLibStream.s`.

### Zero Page Map (`EasySD/Loader/CartZpMap.inc`)

Single source of truth for all ZP allocation. All labels use `ZP_` prefix.

| Addresses | Purpose |
|-----------|---------|
| `$64-$77` | Low-level communication (ZP_IRQ_DATA_LOW/HIGH, ZP_IRQ_STATUS) |
| `$80-$87` | LoadFileBySize API (ZP_LF_SIZE0..3, ZP_LF_PAYLOAD_LO/HI) - strictly reserved |
| `$8B-$8E` | SafeStream parameters (ZP_SS_INTERVAL, ZP_SS_CHUNK) |
| `$90-$95` | StreamLargeFile (ZP_STREAM_TARGET_ADDR_LO/HI, ZP_STREAM_BYTES_REMAIN_0..3) |
| `$FB-$FE` | Free range for plugin-specific temporary use |

### Plugin Architecture

Each plugin is a standalone 6502 program loaded from `/PLUGINS/` on the SD card. Plugins must:
- Save VIC/CPU state on entry (`SAVESTATE` pattern)
- Exit via `JSR IRQ_ExitToMenu`
- Use `ERROR_GATE` macro after file operations
- Use `LoadFileBySize` for loading, `SafeStream` for audio streaming

Built-in plugins: PRG launcher, KOA viewer, PETG viewer, WAV player, MUS player, CvdPlayer (Bad Apple!! CVD video).

## Critical Arduino Constraints

**ATmega328P has only 2KB SRAM** (~415 bytes free after boot). Every byte matters.

- **Never use `strtok()`** — causes static buffer corruption. Use manual token parsing (see `DirFunction.cpp`).
- **Never use unbounded `strcpy()`** — always validate buffer sizes.
- **Never use Arduino `String` class** — costs ~1700 bytes of flash. Use `char[]` instead.
- **Limit local arrays to 32-64 bytes** to avoid stack overflow.
- **Monitor memory with `FreeStack()`** — aim for 300+ bytes free minimum.
- **SdFat 2.x API only:** Use `File` type (not deprecated `SdFile`), 1-parameter `openNext()`.
- **SPI speed:** Use `SPI_QUARTER_SPEED` for reliable SD communication.
- **Directory navigation must use relative paths from root:** `sd.chdir()` then `sd.chdir("DIRNAME")` — absolute paths fail.
- **SD error recovery:** After any SD error, call `recoverSD()` to reinitialize the card and resync `dirFunc`. Critical for C64 service reliability.

## Key File Locations

| File | Purpose |
|------|---------|
| `EasySD/Loader/CartZpMap.inc` | Zero Page allocation (single source of truth) |
| `EasySD/Loader/CartLibHi.s` | High-level C64 APIs (LoadFileBySize) |
| `EasySD/Loader/CartLibStream.s` | Streaming API (SafeStream, StreamLargeFile) |
| `EasySD/Menus/EasySD/IrqLoaderMenuNew.s` | Main menu program |
| `EasySD/Menus/EasySD/menu.asm` | PETMATE frame export (edit in PETMATE, re-export here) |
| `Arduino/EasySD/EasySD.ino` | Arduino entry point |
| `Arduino/EasySD/CartApi.cpp` | Command routing (new commands register here) |
| `Arduino/EasySD/DirFunction.cpp` | Directory navigation |
| `Tools/build.py` | Unified build system (v3.0.0, includes PETMATE conversion) |
| `Tools/test_arduino_comm.py` | PC-side Arduino serial test runner |
| `Tools/test_vice_menu.py` | VICE automated C64 menu test suite |
| `Tools/prepare_test_sd.py` | SD card test file preparation |
| `GEMINI.md` | Detailed AI developer guide with architectural rules |
| `docs/build/BUILD_SYSTEM.md` | Build system deep-dive |
| `docs/testing/VICE_MENU_TEST.md` | VICE automated test documentation |
| `docs/arduino/DIR_NAVIGATION_API.md` | Directory navigation API reference |

## Serial Debug & Testing

Baud rate: 57600. Debug log prefixes: `[SD]`, `[DIR]`, `[FILE]`, `[ERR]`, `[MEM]`, `[T]`. Enable with `debug-arduino` build target or `--debug` flag on Arduino commands.

**Self-test:** Send `T` via serial to run the on-device test suite (8 tests: SD init, file read, seek, non-existent file, write/delete, memory stability, root listing, directory navigation).

```bash
# Prepare SD card with test files
python Tools/prepare_test_sd.py D:

# Run automated test suite from PC (Arduino)
python Tools/test_arduino_comm.py COM4 --verbose

# Run automated VICE menu tests (C64, requires VICE 3.9+)
python Tools/test_vice_menu.py --build --verbose
```
