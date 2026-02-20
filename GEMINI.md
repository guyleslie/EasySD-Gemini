# EasySD Gemini - Developer Assistant Guide (GEMINI.md)

This document is designed for AI assistants (Gemini, Claude, etc.) to understand the development of the EasySD / IRQHack64 project. It contains key technical parameters, conventions, and architectural rules.

---

## Project Overview
EasySD is an SD card interface for the Commodore 64, consisting of an Arduino-based "file server" and a C64-side menu/plugin architecture.

- **C64 Side**: 6502 Assembly (64tass assembler).
- **Arduino Side**: C++ (Arduino Nano/Pro Mini, ATmega328P).
- **SD Library**: SdFat 2.x (migrated from 1.x in v2.0.4, full P1 API compliance in v2.0.5).
- **Communication**: Custom PWM-like software serial (C64 -> Arduino) and NMI-driven byte transfer (Arduino -> C64).
- **Current Version**: v2.0.5 (Sprint 2 Complete - 2025-12-25)

---

## C64 Development Rules (64tass)

### 1. Linear Include Chain
64tass does not support include guards. To avoid "duplicate definition" errors, a strict hierarchy must be followed. Always include the highest-level wrapper required for your code.

Hierarchy:
CartLibStream.s -> CartLibHi.s -> CartLib.s -> CartLibCommon.s -> System.inc / IRQHack.inc

Example for a plugin:
```assembly
.include "../../Loader/CartLibStream.s" ; This imports everything: ZP map, System, and Hi-level APIs
```

### 2. Zero Page Usage (Single Source of Truth)
Use only the labels defined in the CartZpMap.inc file, prefixed with ZP_.

| Addresses | Function | Key Labels |
|:---|:---|:---|
| $64-$77 | Low-level communication | ZP_IRQ_DATA_LOW/HIGH, ZP_IRQ_STATUS |
| $80-$87 | LoadFileBySize (Strictly reserved!) | ZP_LF_SIZE0..3, ZP_LF_PAYLOAD_LO/HI |
| $8B-$8E | SafeStream parameters | ZP_SS_INTERVAL, ZP_SS_CHUNK |
| $90-$95 | StreamLargeFile (Large files) | ZP_STREAM_TARGET_ADDR_LO/HI, ZP_STREAM_BYTES_REMAIN_0..3 |
| $FB-$FE | Free range (User range) | For plugin-specific temporary variables. |

### 3. Plugin Conventions
- Entry: Save VIC and CPU state using the SAVESTATE pattern.
- Exit: Always return using the JSR IRQ_ExitToMenu call.
- Error Handling: Use the ERROR_GATE macro after file operations.
- Location: Plugins reside in the /PLUGINS/ directory on the SD card.

---

## Key APIs

### LoadFileBySize (CartLibHi.s)
The standard way to load file content (max 64KB).
1. Call IRQ_GetInfoForFile to retrieve the file size.
2. Copy the size to ZP_LF_SIZE0..3.
3. Set the target address in ZP_LF_PAYLOAD_LO/HI.
4. JSR LoadFileBySize.

### SafeStream (CartLibStream.s)
For time-critical continuous data streaming (e.g., audio).
- Pass profile in accumulator: LDA #STREAM_NORMAL, JSR SafeStream.

---

## Arduino Firmware (C++)

### Core Architecture
- **Main entry point**: Arduino/IRQHack64/IRQHack64.ino
- **Command processing**: CartApi.cpp (new commands must be registered here)
- **SD Management**: DirFunction.cpp (directory iteration and navigation)
- **Hardware**: Arduino Nano/Pro Mini connects to C64 bus and toggles NMI line for data transfer

### SdFat 2.x Migration (v2.0.4 → v2.0.5 Complete)
**Critical Changes from SdFat 1.x:**
- ✅ `SdFile` → `File` type (completed in v2.0.5, DirFunction.cpp:186, 228)
- ✅ `openNext()` API: 2 parameters → 1 parameter (completed in v2.0.5, DirFunction.cpp:212, 241)
- Removed: `vwd()`, `SdFatUtil.h`
- Added: `FreeStack()` replaces `FreeRam()`
- **Navigation**: MUST use relative paths from root, not absolute paths
  - ❌ `sd.chdir("/UTILS")` fails
  - ✅ `sd.chdir()` then `sd.chdir("UTILS")` works

**P1 API Compliance Status (v2.0.5):**
- ✅ Modern `File` type in use (no deprecated `SdFile`)
- ✅ Simplified `openNext()` API (O_READ implicit default)
- ⏳ P2: `openCwd()` integration (planned for v2.1.0)

### Memory Safety (Critical - Sprint 1 Fixes)
**Never use these in Arduino code:**
1. **strtok()** - Static buffer corruption in multi-threaded parsing
   - Use manual token parsing instead (see DirFunction.cpp:130-175)
2. **Unbounded strcpy()** - Always validate buffer sizes first
3. **Arduino `String` class** - Costs ~1700 bytes of flash. Use `char[]` instead.
4. **Stack-heavy functions** - Limit local arrays to 32-64 bytes max

**Memory Constraints (ATmega328P):**
- Flash: 30720 bytes max (old bootloader). Debug build: ~30658 (99.8%)
- SRAM: 2KB (1633 used, ~415 bytes free after boot)
- Stack: Monitor with `FreeStack()` - aim for 300+ bytes minimum

### SD Card Error Handling & Recovery
**SdFat error codes encountered:**
- `0x21` = `SD_CARD_ERROR_WRITE_TIMEOUT` — Flash programming timeout
- `0x19` = `SD_CARD_ERROR_READ_TOKEN` — Bad read data token (SPI signal issue)

**Critical rule:** Write errors corrupt SdFat internal state. All subsequent operations (including reads and directory listings) will fail until recovery.

**Recovery pattern (see `recoverSD()` in IRQHack64.ino):**
```cpp
dirFunc.CloseDirHandle();   // Close open dir handle first
delay(50);                  // Let card settle
sd.begin(chipSelect, SPI_QUARTER_SPEED);  // Reinitialize
dirFunc.ForceReset();       // Resync directory state
```

**SPI speed:** Use `SPI_QUARTER_SPEED` for reliable operation. `SPI_HALF_SPEED` causes intermittent errors on breadboard setups. Add `delay(50-100)` between rapid SD operations.

### DirFunction.cpp Best Practices
**Correct Navigation Pattern (v2.0.4):**
```cpp
// Always navigate from root with relative paths
sd.chdir();  // Return to root
sd.chdir("UTILS");  // Relative navigation
sd.chdir("UTILS2"); // Next level
```

**File Handle Management:**
- Always close `m_dirFile` in `ToRoot()` before reopening
- Check `isOpen()` before closing to prevent errors
- Use `sd.open(currentPath)` for directory handles

### Build System
**Primary tool**: `Tools/build.py` (unified build system v2.2.0)
```bash
# Arduino compile (release / debug)
python Tools/build.py arduino-compile
python Tools/build.py arduino-compile --debug

# Compile + Upload
python Tools/build.py arduino-upload COM4
python Tools/build.py arduino-upload COM4 --debug

# Serial monitor
python Tools/build.py arduino-monitor COM4
```

### Testing Tools
```bash
# Prepare SD card with test files
python Tools/prepare_test_sd.py D:

# Run automated self-test suite via serial
python Tools/test_arduino_comm.py COM4 --verbose

# Interactive serial mode
python Tools/test_arduino_comm.py COM4 --interactive
```

**C64 Build Commands:**
```bash
# Full project build (C64 + Arduino headers)
python Tools/build.py release

# Debug build (C64 only, mock data)
python Tools/build.py debug

# Debug build (C64 + Arduino, recommended)
python Tools/build.py debug-arduino
```

**Features:**
- Uses `arduino-cli` for reliable compilation
- Auto-detects Arduino Nano ports
- Integrated serial monitor (57600 baud)
- Debug output for troubleshooting
- One-time library installation

---

## Important File Paths

### C64 Side
- **ZP Map**: IRQHack64/Loader/CartZpMap.inc
- **Hardware Constants**: IRQHack64/Loader/Common/IRQHack.inc
- **Standard C64 Addresses**: IRQHack64/Loader/Common/System.inc
- **Main Menu Logic**: IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s
- **C64 Build System**: Tools/build.py

### Arduino Side
- **Main Sketch**: Arduino/IRQHack64/IRQHack64.ino
- **Directory Navigation**: Arduino/IRQHack64/DirFunction.cpp / .h
- **SD Command API**: Arduino/IRQHack64/CartApi.cpp
- **String Buffer**: Arduino/IRQHack64/StringPrint.cpp (32-byte buffer, index < 31)
- **Arduino Build System**: Tools/arduino_build_upload.py

### Documentation
- **Unified Changelog**: CHANGELOG_UNIFIED.md (v1.x to v2.0.5)
- **Sprint 1 Results**: SPRINT1_COMPLETION.md (v2.0.4)
- **Sprint 2 Results**: SPRINT2_COMPLETION.md (v2.0.5)
- **Sprint 2 Planning**: SPRINT2_PLAN.md, SPRINT2_TESTING_GUIDE.md
- **SdFat Migration**: SDFAT2_MIGRATION_ROADMAP.md (complete status)

---

## Sprint 1 Summary (v2.0.4 - Production Ready)

### Goals Achieved ✅
- **Stable directory navigation** across multiple levels (Root → UTILS → UTILS2)
- **Memory leak elimination** (stable 341-425 bytes free RAM)
- **Buffer overflow fixes** (StringPrint 94-byte overflow, strtok corruption)
- **SdFat 2.x full compatibility**

### Critical Bugs Fixed
1. **strtok() Concurrent Corruption** - Replaced with thread-safe token parser
2. **StringPrint Buffer Overflow** - Fixed boundary check (127 → 31)
3. **Relative Navigation** - Root-based navigation for SdFat 2.x compatibility
4. **Stack Optimization** - 75% reduction (216 → 56 bytes in ChangeDirectory)

### Test Results (v2.0.4 Baseline)
```
Memory Trajectory (10+ cycles tested):
Boot:          425 bytes
Root Prepare:  341 bytes (-84)
UTILS enter:   333 bytes (-8)
UTILS2 enter:  332 bytes (-1)
Root reset:    341 bytes (+9) ← Returns to baseline
```
**Result**: No memory leaks, stable operation confirmed.

---

## Sprint 2 Summary (v2.0.5 - API Modernization Complete)

### Goals Achieved ✅
- **SdFat 2.x Full P1 API Compliance** - Modern `File` type, simplified `openNext()` API
- **Zero functional regression** - Baseline + Regression testing strategy (8/8 tests PASS)
- **Memory improvement** - Unexpected +4-12 bytes improvement across all metrics
- **Production-ready** - 4 lines changed, complete deprecated API removal

### Changes Implemented
1. **P1-1: SdFile → File Migration** (DirFunction.cpp:186, 228)
2. **P1-2: openNext() API Update** (DirFunction.cpp:212, 241)

### Test Results (v2.0.5 Regression)
```
Memory Trajectory (10+ cycles tested):
Boot:          437 bytes (+12 vs v2.0.4)
Root Prepare:  345 bytes (+4 vs v2.0.4)
UTILS enter:   337 bytes (+4 vs v2.0.4)
UTILS2 enter:  336 bytes (+4 vs v2.0.4)
Root reset:    345 bytes ← Returns to baseline
```
**Result**: Memory improved, zero regression, all tests PASS.

### Remaining Tasks (Sprint 3+)
- ⏳ P2: `openCwd()` integration (planned for v2.1.0)
- ⏳ P3: Global `strcpy()` → `strncpy()` review
- ⏳ P3: "open fail" anomaly investigation

---

## Development Workflow

### When modifying Arduino code:
1. Read existing code first with Read tool
2. Check memory constraints (SRAM: 2KB limit, ~437 bytes free after boot)
3. Avoid `strtok()`, use manual parsing (see DirFunction.cpp for pattern)
4. Use modern SdFat 2.x API (`File` type, 1-param `openNext()`)
5. Build: `python Tools/build.py debug-arduino` (recommended for full system)
6. Upload: `python Tools/arduino_build_upload.py upload COM4`
7. Monitor serial output (57600 baud) for memory leaks with `FreeStack()`

### When modifying C64 code:
1. Follow linear include chain (CartLibStream.s is highest level)
2. Use only `ZP_` prefixed labels from CartZpMap.inc
3. Build with `python Tools/build.py debug` for testing
4. Build with `python Tools/build.py release` for production

### Documentation updates:
- Always update `CHANGELOG_UNIFIED.md` for version changes
- Create sprint completion docs for major milestones (see SPRINT1_COMPLETION.md, SPRINT2_COMPLETION.md)
- Update `GEMINI.md` when adding new architectural rules
- Use baseline + regression testing strategy for API changes (see SPRINT2_TESTING_GUIDE.md)

---

**Last Updated**: 2025-12-25 (v2.0.5 - Sprint 2 Complete)
**Status**: Production-ready, SdFat 2.x P1 API compliance complete, Sprint 3 planning phase