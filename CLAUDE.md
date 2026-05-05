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

# Build only core or only plugins
python Tools/build.py core
python Tools/build.py plugins

# Clean all build artifacts
python Tools/build.py clean

# Arduino-specific commands
python Tools/build.py arduino-compile [--debug]
python Tools/build.py arduino-upload-isp [--debug] [--isp-sck USEC]
python Tools/build.py arduino-monitor COM4

# Skip Arduino artifact generation during C64 builds
python Tools/build.py release --skip-arduino
```

**Hardware debug workflow** (real C64 + Arduino serial logging):
```bash
deploy-debug.bat
# = python Tools/build.py release --skip-arduino
#   python Tools/build.py arduino-upload-isp --debug
#   python Tools/build.py sd-deploy D:
```

**Prerequisites:** `64tass` and `petcat` (VICE) in PATH, `arduino-cli` installed, Python 3.7+.

**First-time Arduino setup:** `python Tools/build.py arduino-setup`

**Arduino upload notes:**
- `arduino-upload-isp` uses USBtinyISP programmer (ISP only — no bootloader). USB serial upload is intentionally unsupported because any bootloader's startup window breaks the EasySD cold-boot sequence.
- ISP SCK speed: `--isp-sck 2` (500 kHz, default) for chips with existing firmware; `--isp-sck 100` (10 kHz, ~8 min) for blank/bricked chips
- **Debug flash budget:** EASYSD_DEBUG_SERIAL gates all log output; the `h`/`m` interactive console and the standalone self-test/protocol-test suites have been removed. With MultiLoad/MLBoot stripped out, debug builds regain roughly 1.5 KB of flash headroom — re-measure with `arduino-compile --debug` after the next build.

## Architecture

### Dual-System Design

**Arduino firmware** (`Arduino/EasySD/`): Manages SD card, FAT filesystem, directory navigation, file streaming. Entry point is `EasySD.ino`, command routing in `CartApi.cpp`, directory logic in `DirFunction.cpp`. Cold boot is **IRQHack64-style**: AVR does NOT hold C64 `/RESET`. `IOSetup()` drives `/RESET` HIGH from the start; the C64 cold-boots to BASIC on its own RC reset while AVR initializes SD in parallel. `TransferMenu()` is invoked only on explicit short `SEL` press. If SD fails, the C64 is already in BASIC and `SEL` can retry SD init.

**Hardware caveats:**
- Cartridge edge-connector / SD-module-header contact integrity matters: if behavior changes when the cartridge or SD module is touched, treat that as a hardware integrity symptom first, not as proof of a firmware regression.
- **Parasitic loads on the C64 power rail** (Pi1541 Zero adapter, MicroSD2IEC, etc.) can destabilize cold boot — verified on the uEliteBoard64 (uni64.com — MMU-252535-based C64 reproduction board) where removing the Pi1541 Zero from the integrated SD CARD/IEC PORT slot was a co-required fix alongside the IRQHack64-style boot. The board's own first-start guide notes "no blinking cursor (especially with a cartridge plugged in) → try another CPU/251715/CIA 6526" — i.e. cartridge-sensitivity at cold boot is a known board-class behavior, not just a firmware bug. Test cold-boot regressions with no auxiliary devices first.

**C64 software** (`EasySD/`): Cartridge ROM with communication library (`Loader/`), main file browser menu (`Menu/EasySD/EasySDMenu.s`), and file-type plugins (`Plugins/`).

### Build Artifact Flow

PETMATE `petmate frame.asm` → `convert_petmate_asm()` → `menu.bin` → C64 assembly (`.binary "../../build/menu.bin"`) → 64tass → `.prg` binaries → `bin2ardh` → `build/artifacts/FlashLib.h` → copied to `Arduino/EasySD/` → `arduino-cli compile` → firmware HEX. Use `release --skip-arduino` to skip Arduino artifact regeneration.

### C64 Include Hierarchy (strict linear chain, no include guards in 64tass)

```
CartLibStream.s → CartLibHi.s → CartLib.s → CartLibCommon.s → System.inc / EasySD.inc
```

Plugins include the highest-level wrapper they need. For most plugins: `CartLibStream.s`.

**Macro tiers — this distinction is critical:**
- **Tier 1 — `SystemMacros.s`**: `#SETBANK`, `#WAITFOR`, `#SAVEREGS`/`#RESTOREREGS`, `#READCART`, `#READCART_MODULATED` — pulled in automatically via `CartLib.s` (line 16), forward-referenceable across the include chain
- **Tier 2 — `APIMacros.s`**: `#OPENFILE`, `#GETFILEINFO`, `#EXTRACTFILESIZE`, `#CLOSEFILE`, `#SETADDR` — must be explicitly `#include`d at the top of any file that uses them; **not** in `SystemMacros.s` to avoid duplicate macro errors

### Zero Page Map (`EasySD/Loader/CartZpMap.inc`)

Single source of truth for all ZP allocation. All labels use `ZP_` prefix.

| Addresses | Purpose |
|-----------|---------|
| `$64-$77` | Low-level communication (ZP_IRQ_DATA_LOW/HIGH, ZP_IRQ_STATUS, etc.) |
| `$80-$87` | LoadFileBySize API — strictly reserved, never reuse |
| `$8B-$8E` | **Free** (SafeStream params removed — Arduino ignored them) |
| `$90-$95` | StreamLargeFile (ZP_STREAM_TARGET_ADDR_LO/HI, ZP_STREAM_BYTES_REMAIN_0..3) |
| `$FB/$FC` | NAMELOW/NAMEHIGH — navigation indirect pointer — **never use as temp** |
| `$FD/$FE` | COLLOW/COLHIGH — color RAM indirect pointer — **never use as temp** |

Plugin-specific temporaries: use `$FB-$FE` range carefully given the above constraints.

### Plugin Architecture

Each plugin is a standalone 6502 program loaded from `/PLUGINS/` on the SD card. Plugins must:
- Save VIC/CPU state on entry (`SAVESTATE` pattern)
- Exit via `JSR PROT_ExitToMenu`
- Use `ERROR_GATE` macro after file operations
- Use `LoadFileBySize` for loading; audio streaming via `JSR PROT_Stream` (SafeStream removed)

**Current plugins — all APIMacros adopted (Sprint 16, binary-verified):**

| Plugin | Extension | Real HW status |
|--------|-----------|----------------|
| KernalBridge (PRG loader, P2TK) | `.PRG` | ✅ working |
| WavPlayer | `.WAV` | ❌ needs debug |
| KoalaDisplayer | `.KOA` | ❌ needs debug |
| PetsciiDisplayer | `.PET` | ❌ needs debug |
| CvdPlayer (CVD video player) | `.CVD` | ❌ needs debug |
| HWTest (signal diagnostic) | `.HWT` | ❌ needs debug |

**KernalBridge** handles PRGs that load into `$C000+` via a three-phase transfer kernel (P2TK). Trigger: `ENDADDRESS > $C002`. Data tables stored at `$C003`/`$C02A` (KernalBridge gap, always-readable RAM).

## Critical Arduino Constraints

**ATmega328P has only 2KB SRAM** (~530B free at boot in release, ~353B in debug). Every byte matters.

- **Never use `strtok()`** — causes static buffer corruption. Use manual token parsing (see `DirFunction.cpp`).
- **Never use unbounded `strcpy()`** — always validate buffer sizes.
- **Never use Arduino `String` class** — costs ~1700 bytes of flash. Use `char[]` instead.
- **Limit local arrays to 32-64 bytes** to avoid stack overflow.
- **Monitor memory with `FreeStack()`** — aim for 300+ bytes free minimum.
- **SdFat 2.x API only:** Use `File` type (not deprecated `SdFile`), 1-parameter `openNext()`.
- **SPI speed:** Use `SPI_HALF_SPEED` (8 MHz) — tested stable on breadboard (8/8 tests pass). `SPI_QUARTER_SPEED` is no longer needed.
- **Directory navigation must use relative paths from root:** `sd.chdir()` then `sd.chdir("DIRNAME")` — absolute paths fail on nested paths.
- **SD error recovery:** After any SD error, call `recoverSD()` to reinitialize the card and resync `dirFunc`. Critical for C64 service reliability.
- **Cartridge idle state must be truly BASIC-safe:** hide cartridge (`EXROM` HIGH), reset receive/session state, and tristate the data bus without leaving AVR pull-ups latched on D4-D7/A0-A3. Use the centralized `ReleaseToBasic()` / `EnterBasicSafeMode()` path instead of re-creating this sequence ad hoc.
- **No active EEPROM persistence:** the current firmware does not use the Nano's internal EEPROM for boot, menu navigation, or last-directory restore. Treat any remaining EEPROM references as stale or legacy code unless reintroduced deliberately.
- **SRAM overlay:** IO2 streaming, NI streaming, and command argument buffers share a single union (`sharedBuf` in CartApi.cpp). These are mutually exclusive at runtime, so `max(128, 400, 130) = 400 B` instead of `658 B`. Never add a new static buffer without checking the SRAM budget.
- **Flash budget:** Re-measure after the next build — MultiLoad/MLBoot removal frees roughly 1.5 KB of release flash and the same in debug.

## Key File Locations

| File | Purpose |
|------|---------|
| `EasySD/Loader/CartZpMap.inc` | Zero Page allocation (single source of truth) |
| `EasySD/Loader/SystemMacros.s` | Tier 1 macros (auto-included via CartLib.s) |
| `EasySD/Loader/APIMacros.s` | Tier 2 macros (explicit include required) |
| `EasySD/Loader/CartLibHi.s` | High-level C64 APIs (LoadFileBySize) |
| `EasySD/Loader/CartLibStream.s` | Streaming API (SafeStream, StreamLargeFile) |
| `EasySD/Menu/EasySD/EasySDMenu.s` | Main menu program |
| `EasySD/Menu/EasySD/petmate frame.asm` | PETMATE frame export (edit in PETMATE, re-export here) |
| `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s` | P2TK PRG loader bridge |
| `Arduino/EasySD/EasySD.ino` | Arduino entry point |
| `Arduino/EasySD/CartApi.cpp` | Command routing (register new commands here) |
| `Arduino/EasySD/DirFunction.cpp` | Directory navigation, `currentPath[64]` |
| `Arduino/EasySD/EasySDLog.h` | Logging macros, category enable flags (`LOG_ENABLE_*`) |
| `Tools/build.py` | Unified build system |
| `GEMINI.md` | Detailed AI developer guide (SdFat patterns, error codes, ZP rules) |
| `docs/arduino/PCB_BRINGUP_NOTES.md` | PCB hardware bringup findings (power, caps, ISP upload) |

## Serial Debug

Baud rate: 57600. Log format: `[LEVEL][CATEGORY] message` (e.g. `[INFO][SD] SD OK`, `[ERR][DIR] chdir failed`). Categories: `SYS`, `SD`, `DIR`, `FILE`, `PROTO`, `PRG`, `ERR`. Enable with `arduino-compile --debug` (or `arduino-upload-isp --debug`). Category compilation controlled by `LOG_ENABLE_*` flags in `EasySDLog.h` — `PRG` and `PROTO` are OFF by default to save flash. Real-hardware debug is the supported workflow: run `deploy-debug.bat`, then `python Tools/build.py arduino-monitor COM4` to view live logs while testing the cartridge in a C64. The previous `h` (help) and `m` (memory) interactive serial commands and the on-device self-test/protocol-test suites have been removed; RAM budget is observed via the event-driven `logRamBudget()` calls on boot/ready.
