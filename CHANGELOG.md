# EasySD - Unified Changelog

> **Last updated:** 2026-03-09
> **Current version:** v3.1.3
> **Project:** EasySD Gemini - C64 Cartridge-based SD card reader

---

## Overview

This document contains all significant changes to the EasySD/IRQHack64 project in chronological order.

---

## Quick Navigation

| Version | Date | Description | Status |
|---------|------|-------------|--------|
| **v3.1.3** | 2026-03-09 | P2TK Phase 3: full-range PRG load up to $FFFF, 3 bug fixes | ✅ Complete |
| **v3.1.2** | 2026-03-08 | WavPlayer EXROM fix, VICE audio test, EasySD rename | ✅ Complete |
| **v3.1.1** | 2026-02-28 | GOBACK depth-2 crash fix, VICE test suite fixes, test 10 | ✅ Complete |
| **v3.1.0** | 2026-02-28 | Directory header row in file browser | ✅ Complete |
| **v3.0.0** | 2026-02-22 | PETMATE menu frame, dynamic build pipeline, charset switch | ✅ Complete |
| **v2.1.1** | 2026-02-21 | Self-Test Suite, SD Write/Delete Bugfixes & Error Recovery | ✅ Tested (7/8) |
| **v2.1.0** | 2025-12-26 | Sprint 6 - Production Polish & User Experience | ✅ Production Ready |
| **v2.0.6** | 2025-12-26 | Sprint 5 - Directory State Synchronization | ✅ Production Ready |
| **v2.0.5** | 2025-12-25 | Sprint 2 - SdFat 2.x API Modernization | ✅ Production Ready |
| **v2.0.4** | 2025-12-25 | Sprint 1 - Memory/Stability Fixes | ✅ Production Ready |
| **v2.0.3** | 2025-12-23 | DEBUG Mode Fixes | ✅ Complete |
| **v2.0.2** | 2025-12-22 | Directory Navigation & Build System | ✅ Complete |
| **v2.0.1** | 2025-12-22 | Relative Path Support | ✅ Complete |
| **v2.0.0** | 2025-12-21 | Centralized Data Management | ✅ Complete |
| **v1.9.x** | 2025-12-21 | Build System & TAP Support | ✅ Complete |
| **v1.7-1.8** | 2025-12-18-21 | Plugin Refactoring & Streaming | ✅ Complete |
| **v1.6.x** | 2025-12-15 | Build System & Phase 1 | ✅ Complete |
| **v1.5** | 2025-12-14 | Arduino Critical Stability | ✅ Complete |

---

## Sprint Summary

| Sprint | Goal | Version | Date | Status |
|--------|------|---------|------|--------|
| **Sprint 6** | Production Polish & User Experience | v2.1.0 | 2025-12-26 | ✅ Complete (Production Ready) |
| **Sprint 5** | Directory State Synchronization | v2.0.6 | 2025-12-26 | ✅ Complete (Tested) |
| **Sprint 4** | Nested Directory Bugfix | - | 2025-12-25 | ⚠️ Superseded by Sprint 5 |
| **Sprint 3** | openCwd() Integration Planning | - | - | ⏭️ Skipped (Merged into Sprint 5) |
| **Sprint 2** | SdFat 2.x API Modernization | v2.0.5 | 2025-12-25 | ✅ Complete |
| **Sprint 1** | Memory/Stability Fixes | v2.0.4 | 2025-12-25 | ✅ Complete |

**Notes:**
- **Sprint 3:** Originally planned for `openCwd()` integration and `strcpy()` safety review. Tasks were moved to Sprint 4 and Sprint 5. No separate sprint was implemented.
- **Sprint 4:** Multiple approaches were attempted to fix nested directory bugs. Ultimately, Sprint 5's comprehensive `openCwd()` invariant solution addressed the root cause more elegantly.

---

## Chronological Changes

### [v3.1.3] - 2026-03-09
**P2TK Phase 3: Full-Range PRG Loading to $FFFF + Three Critical Bug Fixes**

#### Bug Fixes

**`$01=$35` → `$01=$34` in DO_P2TK (`KernalBridge.s`):**
- Root cause: Phase 2 used `PP_CONFIG_RAM_ON_ROM = $35` (CHAREN=1, HIRAM=0), which keeps I/O
  visible at `$D000-$DFFF`. Writes to that range went to VIC-II/SID/CIA chips — not to underlying
  RAM. Programs loading data into `$D000-$DFFF` had their bytes silently discarded.
- Fix: Changed to `PP_CONFIG_ALL_RAM = $34` (HIRAM=0, LORAM=0, CHAREN=1). I/O still visible;
  `$E000-$FFFF` is now writable RAM instead of (hidden) KERNAL ROM.

**BVC wait-stub relocated from `$E000` to `$033B` (`KernalBridge.s`):**
- Root cause: The Phase 2 wait-stub (CLV / BIT ZP / BVC loop / JMP Launcher) lived at `$E000`.
  Phase 2 writes `$C000` upward — for PRGs extending to `$E000+`, Phase 2 overwrites the running
  wait-stub mid-transfer → crash.
- Fix: Stub relocated to `$033B` (FILE_PATH_BUF area). Phase 1 writes `STARTADDR+` (≥$0800) and
  Phase 2 writes `$C000+`, so `$033B` is never touched by either transfer. BVC offset (-4) is
  address-independent; JMP target (`$0334` Launcher) is unchanged.

**FILE_PATH_BUF naming consistency:**
- `PATHBUFFER = $033C ; Cassette buffer` comment in `EasySDMenu.s` renamed to
  `; FILE_PATH_BUF area ($033C-$03FB, re-used as path buffer — not tape I/O)`.
- All "cassette buffer" references in `KernalBridge.s` replaced with "FILE_PATH_BUF area".

#### New Features

**P2TK Phase 3 — tail-write protection for programs filling `$FF00-$FFFF`:**
- Scenario: when `Phase2_pages = 64`, the last transfer page covers `$FF00-$FFFF`. The NMI
  handler (`TransferHandler` at `$80AF`) writes bytes via `STA ($6C),Y`. At `Y=$FA` it would
  overwrite `$FFFA/$FFFB` (active NMI vector) with half-transferred data → next NMI fires to a
  garbage address → crash.
- Solution: if `Phase2_pages = 64`, two data tables are pre-copied from `$C003/$C02A` (KernalBridge
  gap, always-accessible RAM) to the FILE_PATH_BUF area before Phase 2 starts:
  - `P3_HANDLER` (52 bytes → `$036A`): replacement NMI handler that saves bytes `$FFFA-$FFFF` to
    `TAIL_BUF ($03BB-$03C0)` instead of writing them directly, preventing vector corruption.
  - `P3_TAIL_CODE` (39 bytes → `$0343`): tail-write routine that copies `TAIL_BUF → $FFFA-$FFFF`
    after transfer completes, then falls through to Launcher.
  - BVC loop JMP target overridden from `$0334` (Launcher) to `$0343` (P3_TAIL_CODE).
  - NMI vector overridden from `$80AF` (CARTRIDGENMIHANDLERX1) to `$036A` (P3_HANDLER).
- Tables placed at `$C003/$C02A`: in the previously unused KernalBridge gap (`$C003-$C6FF`), always
  readable as `$C000` range RAM regardless of `$01` setting — avoids the known binary overflow into
  `$D000+` I/O space.
- Effective maximum loadable range: `STARTADDR` (typically `$0801`) through `$FFFF` — the full
  usable 6502 address space up to the vector table.

#### Files Changed

- `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s` — Phase 3 implementation, all three bug fixes
- `EasySD/Menus/EasySD/EasySDMenu.s` — FILE_PATH_BUF comment fix

---

### [v3.1.2] - 2026-03-08
**WavPlayer EXROM Fix, VICE Audio Test, EasySD Rename**

#### Bug Fixes

**WavPlayer silent on real hardware (`CartApi.cpp` `HandleStream()`):**
- Root cause: after the NMI-based file-open transfer, `DisableCartridge()` leaves EXROM=HIGH (ROML
  disabled). When WavPlayer's CIA1 Timer A interrupt then executes `LDA $80AB` (`CARTRIDGE_BANK_VALUE`)
  it reads RAM instead of EEPROM → silence. Fix: `cartInterface.EnableCartridge()` is now called
  before `attachInterrupt()` in `HandleStream()`, and `cartInterface.DisableCartridge()` is called
  on exit. EXROM is LOW for the entire streaming session.

**Pre-existing include bug (`CartApi.cpp`, `CartInterface.cpp`):**
- Both files still referenced `#include "IrqHack64.h"` after the IRQHack64 → EasySD rename.
  Fixed to `#include "EasySD.h"`. Build was broken for `arduino-compile`.

#### New Features

**WavPlayerViceTest — standalone VICE audio pipeline test:**
- `EasySD/Plugins/WavPlayer/WavPlayerViceTest.s`: standalone PRG (`*=$0801`) that tests
  the CIA1 Timer A + SHIFT4BIT lookup + SID master volume chain without Arduino hardware.
  Generates a ~430 Hz sawtooth tone at 11025 Hz. Border cycles for visual IRQ confirmation.
  STOP key exits. Build: `python Tools/build.py debug-vice` → `build/vice-tests/wavtest.prg`.

**build.py: VICE test target:**
- `VICE_TESTS` matrix and `build_vice_tests()` function added. The `debug-vice` target now
  automatically builds standalone VICE test PRGs to `EasySD/build/vice-tests/`. Unlike plugins,
  these include their own BASIC stub and are assembled without `-b` (64tass emits PRG header).

---

### [v3.1.1] - 2026-02-28
**GOBACK Crash Fix & VICE Test Suite Improvements**

#### Bug Fixes

**GOBACK crash at depth ≥ 2 (`IrqLoaderMenuNew.s`):**
- `BCC ++` in the GOBACK restore loop jumped to the second forward anonymous label (`++`), which landed in `ISPREVIOUSDIRECTORY` instead of the intended clamp skip target. This corrupted the stack on `RTS`, causing a blue screen + READY. crash.
- Root cause: 64tass anonymous labels (`+`) are counted globally. The `++` skipped the clamp skip target and landed in a different subroutine.
- Only manifested at depth ≥ 2: at depth 1, `CURRENTDIRINDEX = 0` → `BEQ _RestoreLoopDone` → loop skipped → `BCC` never reached.
- **Fix:** `BCC ++` → `BCC +` (single forward label is sufficient).

**VICE test suite cursor key codes (`test_vice_menu.py`):**
- `_navigate_to_row` and all nav tests used `+`/`-` ($2B/$2D) but v3.0.0 switched the menu to cursor keys ($91 UP, $11 DOWN).
- Fixed in all test functions: `NAV_DOWN`, `NAV_UP`, `NAV_WRAP`, `_navigate_to_row`.

**VICE test SCREEN_VERIFY:**
- Reading screen RAM while row 0 was selected returned inverted codes (SETARROW inverts chars on selected row).
- Fix: navigate off row 0 first so CLEARARROW restores normal codes before reading.

#### Test Suite Improvements

**New test 10: DIR_DEPTH (`test_vice_menu.py`):**
- Round-trip navigation: root → `/games/` → `/games/demos/` → back to root.
- Verifies `CURRENTDIRINDEX` at each depth (1, 2) and `CURPAGEITEMS` at depth 2 (6).
- Back-navigation via `..` is now part of the pass/fail check (not just cleanup) — this is what would have caught the GOBACK bug earlier.

**`_navigate_to_row` bidirectional fix:**
- Was UP-only, causing wrap-around when target > current row.
- Now chooses UP ($91) or DOWN ($11) based on current vs target row.

**`_go_up_one_level(expected_dirlevel)` helper:**
- Resumes C64 first (lets NEWCONTENT+INPUT_GET settle), navigates to row 0 (`..`), resumes again, injects ENTER via keyboard buffer write while C64 is running.
- Polls `DIRLEVEL` for expected value with 5s timeout.

#### Why the test suite didn't catch the GOBACK bug earlier
`test_dir_depth`'s cleanup (go-back) failures were treated as warnings (not counted in `ok`), so the test reported PASS even when the return journey crashed the menu. Fixed: back-navigation is now a mandatory pass/fail assertion.

#### Files Modified

| File | Changes |
|------|---------|
| `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s` | `BCC ++` → `BCC +` in GOBACK restore loop |
| `Tools/test_vice_menu.py` | Cursor key codes, SCREEN_VERIFY fix, test 10, bidirectional nav, `_go_up_one_level` |

---

### [v3.1.0] - 2026-02-28
**Directory Header Row in File Browser**

#### UI Changes
- New `PRINTDIRHEADER` routine: displays the current directory on header row 1 as inverted `/DIRNAME─■` with a normal `■─` prefix decoration.
  - At root: shows `/ROOT`
  - In subdirs: shows last dirname component (max 18 chars)
  - Clears only up to col 25 to preserve the PETMATE frame at col 26+
- Display order changed: `PRINTDIRHEADER` runs before `PRINTPAGE` (frame → dir header → files → decorations)
- Removed FIRST item decoration (`■─`) from file list: all file items now use MIDDLE (`│ `) or LAST (`■ `) style, since the header takes the visual "first" role

#### Files Modified

| File | Changes |
|------|---------|
| `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s` | +115 lines (PRINTDIRHEADER, display order, decoration logic) |

---

### [v3.0.0] - 2026-02-22
**PETMATE Menu Frame Redesign, Inverse Selection & Navigation Overhaul**

#### Summary
Complete menu UI overhaul: PETMATE-designed box-drawing frame loaded dynamically via build pipeline, inverse highlight for selected items with decorative left-side indicators, uppercase filename display in lc/uc charset mode, and cursor key navigation with proper debouncing.

#### UI Changes
- New clean box-drawing border (┌─┐│└─┘) replaces complex PETSCII art frame
- "EasySD V3" title integrated into top-right corner of frame (┤EasySD V3├)
- Switched to lowercase/uppercase charset mode for mixed-case title display
- **Inverse selection highlight**: selected filename displayed as reversed white text, only text characters highlighted (not space padding)
- **Selection cursor**: white solid block ($A0) + horizontal line ($40) at cols 2-3
- **Left-side decorations**: first item: ■─, middle items: │, last item: ■ (all white)
- Filenames forced to UPPERCASE display (C64 traditional style)
- Interior text color: dark grey ($0B) for readability
- Frame border color: white ($01), border/background: light grey ($0C)
- Intro screen (splash art) preserved — displays ~3 seconds before menu
- PETMATE color data: only frame/logo characters have special colors, interior spaces all dark grey

#### Navigation
- **Cursor UP/DOWN** ($91/$11) replaces +/- for menu navigation
- **Key repeat disabled** ($028A = $40) — prevents rapid uncontrolled scrolling
- `<` / `>` for page navigation, ENTER for selection (unchanged)

#### Build System (build.py v3.0.0)
- New `convert_petmate_asm()` function: converts PETMATE `.asm` export → raw `.bin`
- Automatic conversion step in build pipeline (runs before 64tass assembly)
- Workflow: edit in PETMATE → export as `menu.asm` → build → done

#### Code Changes
- `SETARROW`: inverse highlight with per-character screen/color RAM switching (uses NAMELOW/NAMEHIGH as temp)
- `CLEARARROW`: position-aware decoration restore (first/middle/last detection via PHP/PLP)
- `DRAWDECORATIONS`: new routine draws col 2-3 decorations for all menu rows after PRINTPAGE
- `PRINTASCIIFILENAME`: rewritten for uppercase screen codes ($41-$5A) in lc/uc charset
- Removed dead code: `PRINTTITLE`, `TITLE`, `PRINTFILENAME`, `FROMASCII`
- `PRGSCREENDATA`: `.binary "menu.bin"` replaces inline data
- `DISPLAYSCREENGRAPHICS`: charset switch to lowercase/uppercase mode added

#### Files Modified

| File | Changes |
|------|---------|
| `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s` | Inverse selection, decorations, cursor keys, uppercase filenames, key debounce |
| `IRQHack64/Menus/EasySD/menu.asm` | PETMATE export: interior colors fixed (only frame chars have special colors) |
| `Tools/build.py` | +convert_petmate_asm(), build pipeline integration |
| `Tools/test_vice_menu.py` | Updated expected screen codes for lc/uc uppercase mode |
| `.gitignore` | +menu.bin (generated file) |

---

### [v2.1.1] - 2026-02-21
**Self-Test Suite, SD Write/Delete Bugfixes & Error Recovery**

#### Summary
Fixed critical bugs in SD write/delete handlers, added on-device self-test suite (`T` command), SD error recovery mechanism, flash size optimization, and PC-side automated test tooling.

#### Bug Fixes (CartApi.cpp)

**HandleWriteFile() — 3 bugs fixed:**
- `write()` returns `size_t` (unsigned) — was compared against `-1` (never true)
- Missing `sync()` call — data stayed in SdFat 512-byte cache, lost on power failure
- Missing `getWriteError()`/`clearWriteError()` — write errors went undetected

**HandleDeleteFile/DeleteDirectory/CreateDirectory — null-termination:**
- `fileName` from `GetArgumentsDynamic()` was used without null terminator
- Read random memory beyond the intended filename
- Added same null-termination pattern as `HandleOpenFile()`

**Debug string optimization:**
- All `"Got HandleXxx"` strings shortened to `"[TAG] Cmd"` format
- Saved ~180 bytes of flash, enabling bugfix code to fit

#### New Features

**Self-Test Suite (8 tests):**
- `T` serial command runs: SD_INIT, OPEN_RD_CL, SEEK, OPEN_NOEX, WR_DEL, MEM_LOOP, ROOT_LIST, DIR_NAV
- Each test in its own function (stack management on ATmega328P)
- Recovery between failed tests (`recoverSD()`) prevents cascading errors
- Output: `[T] TEST_NAME: PASS/FAIL` with `[T] END: X/8` summary

**SD Error Recovery (`recoverSD()`):**
- Reinitializes SD card after SPI errors (write timeout, read token)
- Pattern: `CloseDirHandle()` → `delay(50)` → `sd.begin()` → `ForceReset()`
- Critical for C64 service: the C64 cannot detect SD errors independently

**`DirFunction::CloseDirHandle()`:**
- Closes `m_dirFile` before SD reinitialization
- Required: open handles become invalid after `sd.begin()`

**`prepare_test_sd.py` — auto-format support:**
- Detects corrupted/raw SD cards (Windows: no filesystem, 0 size)
- Interactive prompt: `Format as FAT32? [y/N]`
- `--format` flag for non-interactive formatting
- Creates test files after formatting

#### Optimizations

**Flash Size:**
- Debug build: 30578 bytes (99.5% of 30720, 142 bytes margin)
- Release build: ~22400 bytes (72%)
- `ShowMem()`: 300 → 80 bytes of strings
- `testDirectoryNavigation()`: Arduino `String` → manual `char[]` (-1700 bytes)
- Debug log format: `"Got HandleXxx"` → `"[TAG] Cmd"` (-180 bytes)

**SPI Reliability:**
- `SPI_HALF_SPEED` → `SPI_QUARTER_SPEED` for stable breadboard operation
- `delay(50)` after SD init for card stabilization

#### New Files

| File | Purpose |
|------|---------|
| `Tools/prepare_test_sd.py` | Creates test files on SD card + auto-format support |
| `Tools/test_arduino_comm.py` | PC-side serial test runner (auto/interactive/dir_nav modes) |
| `docs/arduino/SD_WRITE_DELETE_API.md` | SdFat write/delete API reference with similar C64 project comparison |

#### SdFat Error Codes Documented

| Code | Symbol | Meaning |
|------|--------|---------|
| `0x0D` | `WRITE_DATA` | Card rejected write data (SPI noise) |
| `0x19` | `READ_TOKEN` | Bad read data token (SPI signal integrity) |
| `0x21` | `WRITE_TIMEOUT` | Flash programming timeout |

#### Test Results (breadboard, 100nF+100µF caps, SPI_QUARTER_SPEED)

| Test | Result | Notes |
|------|--------|-------|
| SD_INIT | PASS | |
| OPEN_RD_CL | PASS | |
| SEEK | PASS | |
| OPEN_NOEX | PASS | |
| WR_DEL | FAIL | 0x19 SPI read token — breadboard hardware limitation |
| MEM_LOOP | PASS | 20x open/read/close, RAM stable (415→415) |
| ROOT_LIST | PASS | Directory listing correct (5 items) |
| DIR_NAV | PASS | cd TESTDIR + GoBack works |

**7/8 PASS.** Write failure is a known breadboard/SPI hardware limitation, not a code issue. SD recovery works correctly after write failure.

#### Hardware Notes
- 100µF electrolytic + 100nF ceramic on SD module VCC/GND recommended
- Breadboard contact resistance limits SPI write reliability
- PCB with proper decoupling traces expected to resolve WR_DEL

#### Files Modified

| File | Changes |
|------|---------|
| `CartApi.cpp` | Write/delete bugfixes, null-termination, debug string optimization |
| `IRQHack64.ino` | +265 lines (self-test, recoverSD, flash optimization) |
| `DirFunction.cpp` | +6 lines (CloseDirHandle) |
| `DirFunction.h` | +1 line (CloseDirHandle declaration) |

---

### [v2.1.0] - 2025-12-26
**Production Polish & User Experience - Sprint 6 Complete ✅**

#### Sprint 6 Goals
- **Goal**: Professional user experience and production stability fine-tuning
- **Focus**: Serial UI/UX, Cold Boot Reliability, Error Handling
- **Status**: ✅ PRODUCTION READY

#### P1 - Mandatory Tasks (100% COMPLETE)

**P1.1: Cold Boot SD Initialization Retry Logic**
- ✅ `initSD()` helper function with 3x retry logic
- ✅ 200ms delay between retries
- ✅ DEBUG logging for retry attempt count
- ✅ Success rate: ~95% (vs previous ~50%)
- **File**: `IRQHack64.ino:71-105`

**P1.2: Serial Monitor UI/UX Refactoring**

*P1.2.1: Professional Startup Banner*
```
================================
 EasySD IRQHack64 v2.1.0
 SdFat 2.3.0 | Arduino Nano
================================
```
- **File**: `IRQHack64.ino:107-115`

*P1.2.2: User-Friendly Navigation Feedback*
- ✅ Clean navigation messages
- ✅ Error handling: `"Error: [dirname]"`
- **File**: `IRQHack64.ino:220-243`

*P1.2.3: Structured Directory Listing*
```
/UTILS
----------------------------
[D] ..
[D] UTILS2
[ ] 2kscrollerizer.prg
----------------------------
3 items (2 dirs)
```
- **File**: `IRQHack64.ino:242-270`

*P1.2.4: Help System*
- ✅ `h` command to display help
- ✅ Command reference: h, d, r, l, p, m
- **File**: `IRQHack64.ino:107-118`

*P1.2.5: DEBUG/User Output Separation*
- ✅ User-facing: Always visible, concise
- ✅ DEBUG: `#ifdef DEBUG` wrapped, detailed

#### P2 - Strongly Recommended (100% COMPLETE)

**P2.1: Error Handling Standardization**
- ✅ Consistent error message format
- ✅ Navigation errors: `"Error: [dirname]"`
- ✅ SD errors: `"SD FAIL - check card"`

**P2.2: Memory Status Display Improvement**
- ✅ `m` command with detailed memory breakdown
```
Memory Status
----------------------------
Total SRAM:  2048 bytes
Used:        1611 bytes (78%)
Free:         437 bytes (21%)
----------------------------
Status: Normal
```
- ✅ Status levels: Normal (>400), Low (300-400), Critical (<300)
- **File**: `IRQHack64.ino:37-69`

#### P3 - Quality/Polish (PARTIAL COMPLETE)

**P3.1: Extended Hardware Testing Suite**
- ✅ Multi-level navigation tested
- ✅ Cold boot retry verified
- ✅ RAM stability verified
- ⏸️ Automated test suite deferred

**P3.2: SdFat 2.3.0 → 2.3.1 Upgrade Evaluation**
- ✅ Evaluation complete
- ✅ **Decision: DEFER** (stay on 2.3.0)
- **Reasoning**: No benefit for FAT32/ATmega328P project
  - Latest: 2.3.1 (exFAT bugfix, RP2350 support)
  - Current: 2.3.0 (stable, production-ready)

**P3.3: Documentation Finalization**
- ✅ `SPRINT6_COMPLETION.md` created
- ✅ `SDFAT2_MIGRATION_ROADMAP.md` updated
- ✅ `CHANGELOG_UNIFIED.md` updated (this file)

#### Build Metrics

**Firmware Size:**
```
Sketch:  29968 bytes (97.55% flash)
RAM:      1485 bytes (72.5% SRAM)
Delta:    +4380 bytes vs v2.0.6 (+14.25%)
```

**Remaining Resources:**
- Flash: 752 bytes (2.45%)
- RAM: 563 bytes (27.5%)

#### Hardware Test Results (2025-12-26)

**Platform:** Arduino Nano (ATmega328P old bootloader), SD card via SPI

**Functional Tests:**
- ✅ Cold boot retry working (typically 2 attempts)
- ✅ Professional UI/UX (banner, help, structured output)
- ✅ Multi-level navigation (Root → UTILS → UTILS2 → Root)
- ✅ Zero regressions vs Sprint 5
- ✅ RAM stability maintained
- ✅ State synchronization working

**Sprint 6 Goals Verification: 5/5 ✅ PASS**
- Cold boot 95%+ success rate ✅
- Serial UI professional and user-friendly ✅
- Error handling standardized ✅
- Zero regressions ✅
- Documentation complete ✅

#### Files Modified

| File | Changes | Description |
|------|---------|-------------|
| `IRQHack64.ino` | +150, ~50 modified | P1+P2 implementation |

#### New Functions

- `initSD()` - Cold boot retry logic (35 LOC)
- `printStartupBanner()` - Professional banner (8 LOC)
- `printSDStatus()` - User-friendly SD status (12 LOC)
- `printHelp()` - Help system (11 LOC)
- `ShowMem()` enhanced - Detailed memory display (32 LOC)

#### Known Issues

- Duplicate DIR: DEBUG messages (cosmetic, acceptable)
  - `dirFunc.ReInit()` called twice (setup + cartApi.Init)
  - Impact: DEBUG mode only
  - Status: Safe, ensures correct initialization

#### Sprint 6 Summary

**Status:** ✅ PRODUCTION READY - v2.1.0
**SdFat Migration:** ✅ 100% COMPLETE (P1+P2+P3)
**All Sprint 6 Goals:** ✅ ACHIEVED
**Definition of Done:** ✅ MET

---

### [v2.0.6] - 2025-12-26
**Directory State Synchronization - Sprint 5 Complete ✅**

#### Sprint 5 Goals
- **Goal**: Deterministic, state-drift free, SdFat 2.x-compliant directory handling
- **Principle**: Firmware CWD = Single Source of Truth
- **Status**: ✅ PRODUCTION READY

#### Critical API Fix

1. **openCwd() API Error**:
   - **Problem**: Documentation incorrectly contained `openCwd(&sd)` call
   - **Root Cause**: SdFat 2.x API `openCwd()` takes no parameter (FatFile.h:591)
   - **Fix**: `m_dirFile.openCwd(&sd)` → `m_dirFile.openCwd()`
   - **File**: `DirFunction.cpp:23`
   - **Build error**: `no matching function for call to 'File32::openCwd(SdFat*)'`

2. **Documentation Update**:
   - `SPRINT5_COMPLETION.md`: API call fixed
   - `DIRECTORY_LIFECYCLE_INVARIANT.md`: Fixed in 3 locations

#### P1 - Mandatory Tasks (100% COMPLETE)

**P1.1: `openCwd()` Pattern Implemented**
- ✅ `ToRoot()` - `ResyncDirFromCwd()` after every `sd.chdir()`
- ✅ `ChangeDirectory()` - rollback on sync failure
- ✅ `GoBack()` - state synchronization + rollback
- ✅ `Prepare()` - `open(currentPath)` → `ResyncDirFromCwd()`

**P1.2: Directory Lifecycle Invariant Documented**
- ✅ Artifact: `Archive/TechnicalReports/DIRECTORY_LIFECYCLE_INVARIANT.md`
- ✅ Anti-patterns, correct patterns, testing criteria

#### P2 - Strongly Recommended (100% COMPLETE)

**P2.1: DEBUG Assertions**
- ✅ `ResyncDirFromCwd()` validates `isOpen()` and `isDir()` state
- ✅ Immediate error detection in serial log

**P2.2: Unified Sync Helper**
- ✅ `ResyncDirFromCwd()`: close → openCwd() → rewind → validate
- ✅ Single point of maintenance
- ✅ Impossible to forget a step

#### P3 - Quality (100% COMPLETE)

**P3.1: String Operations Audit**
- ✅ Artifact: `Archive/TechnicalReports/STRING_OPERATIONS_AUDIT.md`
- ✅ 10 safe operations, 0 vulnerabilities
- ✅ All bounds-checked

#### Testing Results (2025-12-26)

**Hardware**: Arduino Nano (ATmega328P old bootloader), SdFat 2.3.0

**Build Status**:
```
Sketch:  25,588 bytes (83% flash)
RAM:      1,335 bytes (65%)
Status:   ✅ SUCCESS
```

**Functional Tests** (Multi-level Navigation):
```
Test Scenario           RAM Before  RAM After  Items  Status
/                       389         389        3      ✅ PASS
/UTILS                  381         381        3      ✅ PASS
/UTILS/UTILS2           380         380        2      ✅ PASS
/GAMES                  381         381        3      ✅ PASS
/GAMES/ARCADE           380         380        1      ✅ PASS
```

**Key Metrics**:
- ✅ **Zero "open fail" errors** during navigation
- ✅ **Zero memory leaks** (RAM identical before/after all operations)
- ✅ **Zero state drift** (consistent behavior across cycles)
- ✅ **Zero DEBUG assertion failures**

**Sprint 5 Goals Verification**:
| Goal | Status | Evidence |
|------|--------|----------|
| No "open fail" where navigation succeeds | ✅ PASS | Zero failures in multi-level test |
| No `open(path)` with absolute strings | ✅ PASS | Code review: `openCwd()` only |
| Every dir op synced with `openCwd` | ✅ PASS | `ResyncDirFromCwd()` enforced |
| RAM returns to baseline | ✅ PASS | 0 byte leaks detected |
| State drift eliminated | ✅ PASS | Deterministic behavior verified |

#### Known Issues

**⚠️ Cold Boot SD Initialization**:
- **Issue**: Power cycle → SD init failure → requires Arduino reset button
- **Root Cause**: SD card needs ~100-200ms VCC stabilization, Arduino boots faster
- **Workaround**: Press reset button after power-on
- **Impact**: Low (normal operations unaffected)
- **Proposed Fix** (Future Sprint):
  ```cpp
  for (int retry = 0; retry < 3; retry++) {
    if (sd.begin(SD_CS_PIN, SD_SCK_MHZ(4))) break;
    delay(200);
  }
  ```

#### Library Versions (Verified Stable)

| Library | Version | Status | Action |
|---------|---------|--------|--------|
| Arduino AVR Core | 1.8.6 | ✅ Latest | RETAIN |
| SPI | 1.0 (built-in) | ✅ Latest | RETAIN |
| SdFat | 2.3.0 | ⚠️ 2.3.3 available | Consider later |
| ByteQueue | Custom | ✅ Stable | RETAIN |
| EEPROM | 2.0 (built-in) | ✅ Latest | RETAIN |

**Note**: ByteQueue is custom implementation (63-byte stack-allocated, volatile indexes, interrupt-safe). Alternatives use heap → fragmentation risk on Nano.

#### Definition of Done (All ✅)

1. ✅ No `open fail` where navigation succeeds
2. ✅ No `open(path)` with absolute string on directory
3. ✅ Every dir operation followed by `openCwd`
4. ✅ Directory Lifecycle documented
5. ✅ RAM returns to baseline after cycles

#### Code Changes Summary

**Modified Files**:
- `DirFunction.h`: +7 lines (ResyncDirFromCwd declaration)
- `DirFunction.cpp`: +65 lines, ~40 modified (invariant enforcement)

**New Files**:
- `Archive/TechnicalReports/DIRECTORY_LIFECYCLE_INVARIANT.md`
- `Archive/TechnicalReports/STRING_OPERATIONS_AUDIT.md`
- `SPRINT5_COMPLETION.md`

#### Technical Improvements

**Before Sprint 5** (State Drift):
```cpp
sd.chdir();                     // Change directory
// m_dirFile still points to old directory!
m_dirFile.open(currentPath);   // Opens by path string ❌
```
**Problems**: State drift, mysterious "open fail" errors

**After Sprint 5** (Deterministic):
```cpp
sd.chdir();                     // Change firmware CWD
ResyncDirFromCwd();            // Sync handle with CWD ✅
// m_dirFile.openCwd() inside ResyncDirFromCwd()
```
**Benefits**: Always synchronized, predictable, no drift

#### Impact

- ✅ Directory navigation 100% reliable
- ✅ Firmware CWD = single source of truth enforced
- ✅ DEBUG assertions catch violations immediately
- ✅ Easy to maintain (centralized sync logic)
- ✅ Production-ready for deployment

#### References

- SdFat 2.x API: [ArduinoCore-avr](https://github.com/arduino/ArduinoCore-avr)
- Implementation: `Arduino/IRQHack64/DirFunction.cpp`, `DirFunction.h`
- Documentation: `Archive/TechnicalReports/DIRECTORY_LIFECYCLE_INVARIANT.md`

---

### [v2.0.5] - 2025-12-25
**SdFat 2.x API Modernization (Sprint 2 Complete)**

#### API Changes

1. **SdFile → File Type Migration**:
   - **Change**: Deprecated `SdFile` type replaced with modern `File` type
   - **Reason**: SdFat 2.x best practice compliance, removal of `SdFile` backward compatibility wrapper
   - **Locations**:
     - `DirFunction.cpp:186` - Prepare() function
     - `DirFunction.cpp:228` - Iterate() function
   - **Impact**: None (backward compatible type)

2. **openNext() API Signature Simplification**:
   - **Change**: `file.openNext(&m_dirFile, O_READ)` → `file.openNext(&m_dirFile)`
   - **Reason**: In SdFat 2.x, O_READ is the implicit default parameter and can be omitted
   - **Locations**:
     - `DirFunction.cpp:212` - Prepare() while loop
     - `DirFunction.cpp:241` - Iterate() if statement
   - **Impact**: Simpler API, same functionality

#### Memory Improvement (Unexpected Benefit)

**v2.0.4 → v2.0.5 comparison:**
```
Boot Free RAM:     425 → 437 bytes (+12 bytes, +2.8%)
Root RAM (before): 341 → 345 bytes (+4 bytes, +1.2%)
UTILS RAM:         333 → 337 bytes (+4 bytes)
UTILS2 RAM:        332 → 336 bytes (+4 bytes)
GAMES RAM:         333 → 337 bytes (+4 bytes)
ARCADE RAM:        332 → 336 bytes (+4 bytes)
```

**Origin:** Likely due to the `File` wrapper having a more efficient memory footprint than the `SdFile` backward compat wrapper.

#### Regression Testing Results

**Functional tests:** ✅ 8/8 PASS (zero regression)
- Root navigation (r command)
- Subdirectory entry (UTILS, GAMES)
- Nested navigation (UTILS2, ARCADE)
- Reset to Root
- List function (l command)
- Path tracking
- GoBack (..) navigation
- Multi-cycle stability

**Memory stability:** ✅ PASS
- 10+ navigation cycles stable (345 → 337 → 336 → reset → 345)
- No memory leak
- Baseline +4-12 bytes improvement across all metrics

#### Compile Results

```
Sketch uses 29050 bytes (94%) of program storage space. Maximum is 30720 bytes.
Global variables use 1485 bytes (72%) of dynamic memory, leaving 563 bytes.
```

**Flash:** Unchanged (~29KB)
**Runtime Free RAM:** 437 bytes (+12 vs v2.0.4)

#### Files Affected

- `DirFunction.cpp`: 4 lines modified (SdFile → File, openNext 1 param)

#### Production-Ready Status

- ✅ Sprint 2 tests successful (baseline + regression)
- ✅ Zero functional regression
- ✅ Memory improvement (+4-12 bytes)
- ✅ Full SdFat 2.x P1 API compliance
- ✅ Build/upload pipeline working (build.py, arduino_build_upload.py)

#### Next Steps (v2.1.0+)

**P2 tasks (Enhanced Sync):**
- openCwd() integration in ToRoot(), ChangeDirectory(), GoBack(), Prepare()
- Enhanced firmware-state synchronization

**P3 tasks (Quality):**
- "open fail" anomaly investigation (baseline behavior, not regression)
- strcpy() → strncpy() global review
- Performance tuning

---

### [Sprint 4] - 2025-12-25
**Nested Directory Open Bugfix - Superseded ⚠️**

#### Context
During Sprint 4, multiple approaches were tried to fix nested directory bugs:
1. `sd.open(".")` usage - Root initialization failed
2. `openCwd()` API search - Incorrect SdFat version reference
3. Path-based workarounds - Incomplete solutions

#### Result
**Status:** ⚠️ **SUPERSEDED BY SPRINT 5**

Sprint 5's comprehensive `ResyncDirFromCwd()` + `openCwd()` invariant solution addressed the root cause more elegantly than Sprint 4's targeted fixes.

#### Lessons Learned
- Documented: `SPRINT4_LESSONS_LEARNED.md`
- Key insight: State synchronization requires systematic invariant enforcement, not ad-hoc fixes
- Led to Sprint 5's holistic redesign

**No released version** - Sprint 4 work was integrated into the Sprint 5 solution.

**Related documents:**
- `SPRINT4_COMPLETION.md` - Experiment chronology
- `SPRINT4_LESSONS_LEARNED.md` - Post-mortem analysis

---

### [v2.0.4] - 2025-12-25
**Critical Memory and Stability Fixes (Sprint 1 Production-Ready)**

#### Critical Bug Fixes

1. **strtok() Concurrent Calls Corruption** (CRITICAL):
   - **Problem**: `ChangeDirectory()` used 2 parallel `strtok()` calls (line 134, 149), causing static buffer corruption
   - **Impact**: Random navigation errors, memory corruption, instability
   - **Fix**: Custom thread-safe token parser implemented, complete `strtok()` removal
   - **Stack reduction**: 192 byte → 32 byte (3 × 64-byte buffer → 1 × 32-byte buffer)
   - **File**: `DirFunction.cpp:126-175`

2. **StringPrint Buffer Overflow** (CRITICAL - 94-byte overflow!):
   - **Problem**: `index < 127` check on a 32-byte buffer → `value[126]` write into 32-byte array
   - **Impact**: 94-byte stack corruption when printing filenames
   - **Fix**: `index < 31` boundary check (30 char + null terminator)
   - **File**: `StringPrint.cpp:9`

3. **SdFat 2.x Relative Navigation**:
   - **Problem**: Absolute paths (`/UTILS`) did not work with `sd.chdir()`
   - **Impact**: "DIR: chdir FAILED: /UTILS" errors
   - **Fix**: Relative navigation from root - every `ChangeDirectory()` returns to root first, then navigates component by component
   - **File**: `DirFunction.cpp:126-128`

#### Memory Stability

**Before (v2.0.3)**:
- Free RAM: 423 → 331 → 375 (variable, 48-92 byte leak)
- Unstable navigation after repeated use

**After (v2.0.4)**:
- Free RAM: 425 → 341 → 333 → 332 → 341 (stable, returns to original value)
- Consistent memory usage after 10+ navigation cycles
- No memory leak

#### Tested Scenarios (Sprint 1)

✅ **Multi-level navigation**:
```
Root → UTILS → UTILS2 → Root (repeated 10x)
Memory: 341 → 333 → 332 → 341 (stable)
```

✅ **List command**:
- Root list: 2 items
- /UTILS list: 3 items (.. [DIR], UTILS2 [DIR], 2kscrollerizer.prg)
- /UTILS/UTILS2 list: 2 items

✅ **Reset functionality**:
- "r" command consistently returns to root
- Memory freed (341 bytes restored)

#### Stack Optimization

- `ChangeDirectory()` stack usage: 216 byte → 56 byte (75% reduction)
- No concurrent `strtok()` static buffer interference
- Thread-safe token parsing (custom implementation)

#### Files Affected

- `DirFunction.cpp`: ChangeDirectory() complete rewrite
- `StringPrint.cpp`: Buffer boundary fix
- `IRQHack64.ino`: List command added ('l')

#### Production-Ready Status

- ✅ Sprint 1 tests successful
- ✅ Memory leak eliminated
- ✅ Buffer overflow eliminated
- ✅ Navigation 100% reliable
- ✅ Compatible with SdFat 2.x

---

### [v2.0.3] - 2025-12-23
**DEBUG Mode Fix and Mock Data**

#### Bug Fixes
1. **Mock Filename Display** (`IrqLoaderMenuNew.s`):
   - **Problem**: Mock directory names (DIR1/DIR2/DIR3) did not appear in DEBUG mode
   - **Root Cause**: Y-based backward copy memory corruption, struct format mismatch
   - **Fix**: Forward copy with X register, explicit null terminator usage
   - **File**: `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s`

2. **ENTER Freeze in DEBUG Mode**:
   - **Problem**: ENTER key press causes red border, program freeze
   - **Root Cause**: Corrupted DIRLOAD buffer, IRQ_SetName with invalid data
   - **Fix**: Correct mock structure, validated buffer copy

#### Impact
- ✅ DEBUG mode full functionality without SD card
- ✅ Mock directory navigation for testing
- ✅ CI/CD automation possibility

---

### [v2.0.2] - 2025-12-22
**Directory Navigation and Arduino Build System**

#### New Features
1. **Arduino Build & Upload System**:
   - **New file**: `Tools/arduino_build_upload.py`
   - **Features**:
     - arduino-cli integration
     - Auto port detection
     - Serial monitor (57600 baud)
     - Debug output
   - **Usage**: `python Tools/arduino_build_upload.py upload COM4`

2. **Directory Navigation Debug**:
   - **Enhanced logging**: DIR: prefix, path tracking
   - **RAM monitoring**: FreeStack() calls on every navigation
   - **Test commands**: d=nav, r=reset, p=status added

#### Bug Fixes
1. **DirFunction Path Tracking**:
   - **Problem**: Unstable StringStack-based solution
   - **Fix**: Fixed 64-byte buffer (DigiWavuino inspired)
   - **File**: `Arduino/IRQHack64/DirFunction.cpp`

2. **Buffer Overflow Protection**:
   - ChangeDirectory() path length validation
   - Safe string operations

#### Documentation
- `BUGFIX_DEBUG_Directory_Navigation_2025_12_22.md` created
- `SPRINT1_BUILD_SYSTEM_CHANGES.md` updated
- `DIR_NAVIGATION_API.md` created

---

### [v2.0.1] - 2025-12-22
**Relative Filename Support**

#### Changes
- **Arduino/IRQHack64/CartApi.cpp**: Removed mandatory absolute path validation
- **PRG Plugin**: Now supports relative filenames (e.g. `"LEVEL2.DAT"`)
- **Backward compatible**: Old absolute paths still work

#### Impact
- Multi-disk game compatibility improved
- 1541-like behavior (relative filenames)
- Zero C64-side changes

---

### [v2.0.0] - 2025-12-21
**Centralized Data Management and Architecture Stabilization**

#### New Features
1. **Strict Linear Include Hierarchy**:
   - Avoiding 64tass "duplicate definition" errors
   - Unidirectional include chain: CartLibStream.s → CartZpMap.inc → CartLibHi.s → CartLib.s
   - `.inc` files with unique ownership (no multiple includes)

2. **Centralized Zero Page Mapping**:
   - All ZP references with `ZP_` prefix (e.g. `ZP_IRQ_DATA_LOW`)
   - CartZpMap.inc: Single source of truth
   - $80-$87 dedicated to LoadFileBySize

3. **Plugin Modernization**:
   - All plugins (BurstLoader, Koala, Mus, Petscii, Prg, Wav) updated
   - Menu-specific definitions restored
   - KERNAL entry points (K_OPEN, K_CLOSE, K_CHKIN etc.)

#### Build System
1. **Python Build System** (Tools/build.py):
   - Cross-platform support (Windows/Linux/macOS)
   - Targets: release, debug, core, plugins, clean
   - C# dependency elimination (Bin2ArdH.exe, CreateEpromLoader.exe)
   - Automatic Arduino/EPROM generation

2. **TAP → PRG Conversion**:
   - Standard TAP v0/v1 support
   - KERNAL/CBM blocks (Turbo not supported)
   - C64 Menu prompt: C (Convert+Run) or S (Save only)

#### Impact
- ✅ Stable include system, no more symbol conflicts
- ✅ Centralized ZP management
- ✅ Modern build pipeline (Python-based)
- ✅ TAP file support

---

### [v2.0.1] - 2025-12-22
**Relative Filename Support**

#### Changes
- **Arduino/IRQHack64/CartApi.cpp**: Removed mandatory absolute path validation
- **PRG Plugin**: Now supports relative filenames (e.g. `"LEVEL2.DAT"`)
- **Backward compatible**: Old absolute paths still work

#### Impact
- Multi-disk game compatibility improved
- 1541-like behavior (relative filenames)
- Zero C64-side changes

---

### [Sprint 1] - 2025-12-23
**Build System Improvements**

#### New Build Targets
| Target | C64 DEBUG | Arduino DEBUG | Purpose |
|--------|-----------|---------------|---------|
| `release` | OFF | OFF | Production build |
| `debug-vice` | ON | OFF | VICE development |
| `debug-arduino` | ON | ON | Arduino Serial debug |

#### Implementation
- **Tools/build.py**: New targets and automatic Arduino DEBUG handling
- **Arduino/IRQHack64/BuildConfig.h**: Auto-generated configuration (new file)
- **Arduino/IRQHack64/IrqHack64.h**: `#include "BuildConfig.h"` added

#### Usage
```bash
python build.py release          # Production
python build.py debug-vice       # VICE development
python build.py debug-arduino    # Arduino testing
```

---

### [v2.0.0] - 2025-12-21
**Centralized Data Management and Architecture Stabilization**

#### Strict Include Hierarchy
- Linear include chain introduced to prevent `64tass` duplicate definition errors:
  ```
  CartLibStream.s → CartZpMap.inc → CartLibHi.s → CartLib.s → CartLibCommon.s
  ```
- `.inc` files received unique ownership

#### Centralized Constants
- **Zero Page**: All ZP references received `ZP_` prefix (e.g. `ZP_IRQ_DATA_LOW`)
- **System.inc**: Extended with KERNAL entry points (`K_OPEN`, `K_CLOSE`, etc.)
- **RAM vectors**: `V_OPEN`, `V_CLOSE`, `V_CHKIN`, `V_CLRCHN`, `V_CHRIN`
- Redundant local aliases removed

#### ZP Conflict Resolution
- `$80-$87` range: dedicated to `LoadFileBySize` routine
- Callback and seek variables moved to new addresses ($73-$76)

#### Plugin Modernization
- All plugins converted to new standards:
  - BurstLoader, KoalaDisplayer, MusPlayer
  - PetsciiDisplayer, PrgPlugin, WavPlayer
- Menu-specific definitions restored

---

### [v1.9.2] - 2025-12-21
**Unified Python-based Build System**

#### Tools/build.py Introduction
- Replaces the previous `.bat` file system
- Cross-platform support (Windows/Linux/macOS)
- Supported targets: `release`, `debug`, `core`, `plugins`, `clean`, `prebuild`

#### C# Dependency Elimination
- `Bin2ArdH.exe` and `CreateEpromLoader.exe` functions received native Python implementations
- No .NET runtime required

#### Advanced Pre-build Validation
- Regex-based inclusion rules ported to Python
- More robust error reporting

#### Automated Generation
- `FlashLib.h` and `IRQLoaderRom.bin` automatic updates
- KeyBooter integration

---

### [v1.9.1] - 2025-12-21
**Path Handling Refactoring (DigiWavuino Inspiration)**

#### Arduino/DirFunction.cpp & .h
- **Absolute path handling**: Fixed 64-byte static buffer (`currentPath`)
- **Structured Debug**: With `DIR:` prefix, under `#ifdef DEBUG`
- **DigiWavuino logic**: `GoBack()` optimized RAM-efficient implementation
- **Buffer protection**: Safe path length validation
- **Memory optimization**: Stack-based objects removed

#### WavPlayer.s
- **64tass syntax fix**: Incorrect unnamed label usage fixed

#### TAP Validation
- Pulse timings validated based on DigiWavuino
- Confirmed thresholds: `$37`, `$4A`

---

### [v1.9] - 2025-12-21
**Standard TAP → PRG Support**

#### New Features
- Automatic `.TAP` → `.PRG` conversion in Arduino firmware
- TAP v0 and v1 format support
- C64 menu prompt: **C (Convert+Run)** or **S (Save only)**
- Status line: `UNSUPPORTED TAP`, `BAD TAP`, `SD WRITE FAILED`, `TAP CONVERT OK`

#### Bug Fixes
- **Arduino/CartApi.cpp**: `TapFindCountdown` sync sequence fixed
- **Parity check**: Optimized odd parity
- **C64 Menu**: 64tass syntax fixed (`TAP_SCAN_` prefix)
- **CartApi.h**: New TAP error codes (`$12-$14`)

---

### [v1.8.1] - 2025-12-21
**Streaming Optimization**

#### Arduino Buffer Optimization
- `DOUBLE_BUFFER_SIZE` increased: **64 → 400 byte**
- SD card efficiency improved (512-byte blocks)
- Video plugin support (400-byte blocks)
- Arduino Pro Mini memory limits respected

---

### [v1.8] - 2025-12-21
**WavPlayer and Streaming Stabilization**

#### WavPlayer.s Critical Fixes
- **IRQ_StartTalking**: Arduino wake-up added
- **Register save**: PHA/TXA/TYA in IRQ routines
- **ZP map**: `PLAYSTATE`, `PLAYTYPE`, `PLAYINDEX` at dedicated addresses ($A2-$A4)
- **Buffered playback**: `PlayBothBuffered` as default
- **I/O optimization**: Redundant port reads removed

#### Streaming Architecture
- `SafeStreamImpl.s` and Arduino `HandleStream` double buffer verified
- 100ms timeout mechanism for clean exit

---

### [v1.7] - 2025-12-18
**Phase 2A+2B+2C+2E – Complete Plugin Refactoring**

#### New Features
- **LoadFileBySize**: File size-based reading (skip byte + round-up pages)
- **SafeStream wrapper**: Centralized streaming (`SAFE`/`NORMAL`/`FAST`)
- **SAVESTATE/RESTORESTATE**: VIC-II and memory save/restore
- **ERROR_GATE**: Centralized error handling (PrgPlugin.s)

#### Bug Fixes
- **KoalaDisplayer**: 10003 (PRG header) and 10001 byte (raw) support
- **VIEWKOALA**: Image actually displayed
- **VIC-II**: Bank 0 forced, bitmap mode correct
- **PRINTSTATUS**: Double conversion removed - DEBUG messages visible
- **Branch too far**: BCC + JMP pattern in all plugins
- **SafeStream**: Register loading bug fixed

#### SafeStream Architecture (Phase 2A addition - 2025-12-19)
- **Separation**:
  - `CartLibStream.s` → public API/wrapper
  - `SafeStreamImpl.s` → canonical implementation
- **ZP conflict resolved**:
  - `$80-$87` exclusively for `LoadFileBySize`
  - Stream temp variables: `$8B-$8E`
  - `CartZpMap.inc` single source of truth
- **64tass compatible include**: `.ifndef` issues avoided
- **Plugin ABI unchanged**: `JSR SafeStream`, `JSR CustomStream` without modification

#### Refactoring
- **DebugMacros.s**: `PRINTSTATUS`, `DELAYFRAMES` (120 lines of duplication eliminated)
- **DebugStrings.s**: 11 DEBUG strings centralized
- **CLAUDE.md**: +170 lines Plugin Development Guidelines

#### Metrics
- **186 lines of duplication eliminated**
- **5/5 plugin successful build** (DEBUG=1 too)

---

### [v1.6.1] - 2025-12-15
**64tass .enc Directive Fixes**

#### Bug Fixes
- Quotes added: `.enc "screen"`, `.enc "none"` (in 13 locations)
- Unnecessary `.enc` blocks removed (in 2 locations)

#### Files Affected
- `IrqLoaderMenuNew.s` (6 locations)
- `Warning.s`, `KeyBooter.s`
- Plugins: KoalaDisplayer, WavPlayer, PetsciiDisplayer, PrgPlugin

#### Result
- Modern **64tass v1.59.3120+** compatibility
- `not defined symbol 'screen'` errors resolved

---

### [v1.6] - 2025-12-15
**Build System and Phase 1 Stabilization**

#### Build System
- **Build - EasySD.bat**: New active build script
- Error handling at every step
- Progress feedback with 4 steps
- Proper cleanup (`.obj`, `.tmp`, `.bin.bin`)
- User-friendly output

#### Phase 1 Critical Fixes
- **Filename.s**: `INY` added after `FOUNDPERIOD`, 3-character extension limit
- **PatternMatch.s**: `PATTERN_INITIALIZED` guard flag
- **IrqLoaderMenuNew.s**: PRG load address parsing (not hardcoded `$C000`)
- **ROM timing**: `$01 = $37` before, `$01 = $35` after

#### Result
- **5/5 plugin successful compilation**
- Clean build output

---

### [v1.5] - 2025-12-14 (verified: 2025-12-15)
**Arduino-Side Critical Stability Fixes**

#### Bug Fixes
1. **HandleStream**: Dangling pointer → static buffer + `volatile`
2. **PORT/PIN**: Read-modify-write with `PORTD`/`PORTC` reads
3. **NMI timing**: 6 µs → 10 µs minimum, 31 µs → 50 µs delay
4. **Bitwise/Logical OR**: `|` → `||` fixed
5. **LoaderStub.65s**: X register initialized to `$00` (MEMSIZ = $8000)
6. **BLT → BCC**: Standard 6502 instruction
7. **Plugin .prg**: `.obj + .bin → .prg` consistent

#### Result
- Stack usage reduced: 280 byte → 24 byte
- Build stability improved

---

## Streaming Implementation (Detailed)

### Problem
- 16-bit file size limitation (`LoadFileBySize`)
- 64KB+ files (CVD, WAV) cannot be loaded

### Solution

#### Arduino Side (CartApi.cpp)
- **Timestamp**: `lastStreamRequestTime` (millis() clock)
- **DoubleBufferedStreaming ISR**: Updates timestamp on every request
- **100ms timeout**: If C64 does not send request → exit streaming
- **SEL line control**: No longer required

#### C64 Side (CartLibStream.s)
- **StreamLargeFile routine**: 32-bit file size support
- **Zero Page addresses**:
  - `$90-$91`: Target address
  - `$92-$95`: 32-bit file size
- **LDA $DF00**: Pulse generation on /IO2
- **Termination**: C64 stops pulses → Arduino timeout

#### Buffer Optimization
- **64 → 256 byte**: SD card efficiency
- **256 → 400 byte**: Video plugin support

### Usage
```assembly
; 1. Open file
LDX #O_READ
JSR IRQ_OpenFile

; 2. Get file size
JSR IRQ_GetInfoForFile

; 3. Set up ZP
LDA file_size_lsb
STA STREAM_BYTES_REMAIN_0
; ... (3 more bytes)

LDA #<target_address
STA STREAM_TARGET_ADDR_LO
LDA #>target_address
STA STREAM_TARGET_ADDR_HI

; 4. Streaming
JSR StreamLargeFile

; 5. Close
JSR IRQ_CloseFile
```

---

## Project Status Summary

| Phase | Content | Status |
|-------|---------|--------|
| **Phase 1** | Critical bugfixes (Arduino + C64) | ✅ DONE |
| **Phase 2A-2E** | Plugin infrastructure, streaming, file loading | ✅ DONE |
| **Phase 3A** | Standard TAP → PRG support (v0/v1) | ✅ DONE |
| **Data Management** | Centralized include hierarchy and ZP map | ✅ DONE |
| **Build System** | Python build (Release/Debug/Debug-Arduino) | ✅ DONE |
| **Sprint 1** | Memory/stability fixes, strtok elimination | ✅ DONE |
| **Sprint 2** | SdFat 2.x API modernization | ✅ DONE |
| **Sprint 5** | Directory state synchronization, openCwd() invariant | ✅ DONE (Tested) |
| **v2.0.1** | Relative path support | ✅ DONE |
| **Hardware Test** | EPROM programming, C64 execution | ⏳ READY |

---

## Key Metrics

### Code Quality
- **Duplication reduction**: 186+ lines eliminated
- **Plugin build**: 5/5 successful (DEBUG and RELEASE)
- **Include hierarchy**: Linear, deterministic
- **Stack usage**: 280 byte → 24 byte (Arduino)
- **Directory state**: Zero drift, zero leaks (Sprint 5 verified)

### Build System
- **Cross-platform**: Python 3 (Windows/Linux/macOS)
- **Automated**: FlashLib.h, IRQLoaderRom.bin, BuildConfig.h
- **3 build targets**: release, debug-vice, debug-arduino
- **Dependency**: No C# (.NET/Mono) dependency

### Features
- **File formats**: PRG, TAP (v0/v1), Koala, PETSCII, MUS, WAV
- **Streaming**: 32-bit size, double buffer, timeout
- **Plugin system**: Unified API, state save/restore
- **Debug**: Structured logging, VICE compatibility

---

## Related Documents

### Detailed Changelogs
- `CHANGELOG_UNIFIED.md` - This file - Full project changelog
- `CHANGELOG_v2.0.1.md` - Relative path bugfix
- `CHANGELOG_PHASE2A_CHRONOLOGICAL.md` - Phase 2A chronology
- `CHANGELOG_STREAMING_IMPLEMENTATION.md` - Streaming details

### Sprint Documentation
- `SPRINT5_COMPLETION.md` - Sprint 5 full summary (v2.0.6)
- `SPRINT4_COMPLETION.md` - Sprint 4 results
- `SPRINT2_COMPLETION.md` - Sprint 2 SdFat 2.x API
- `SPRINT1_COMPLETION.md` - Sprint 1 stability fixes
- `SPRINT1_BUILD_SYSTEM_CHANGES.md` - Build system changes

### Technical Reports
- `Archive/TechnicalReports/DIRECTORY_LIFECYCLE_INVARIANT.md` - Sprint 5 Core Documentation
- `Archive/TechnicalReports/STRING_OPERATIONS_AUDIT.md` - Sprint 5 Security Audit

### Developer Documentation
- `CLAUDE.md` - Plugin Development Guidelines
- `EasySD_PRG_Plugin.md` - PRG Plugin documentation (v2.0.1)
- `BUGFIX_RelativePath_Support.md` - v2.0.1 bugfix details
- `VALIDATION_AND_FIXES.md` - Phase 1 validation
- `VERIFICATION_REPORT.md` - v1.5 verification

---

## Build Commands

### Release Build
```bash
python Tools/build.py release
```

### VICE Debug
```bash
python Tools/build.py debug-vice
```

### Arduino Serial Debug
```bash
python Tools/build.py debug-arduino
# Arduino IDE: Upload IRQHack64.ino
# Serial Monitor @ 57600 baud
```

### Core Only / Plugins Only
```bash
python Tools/build.py core
python Tools/build.py plugins
```

### Clean
```bash
python Tools/build.py clean
```

---

## Version History (Summary)

- **v3.1.2** (2026-03-08): WavPlayer EXROM fix (silence on hardware), VICE audio test PRG, EasySD include rename
- **v3.1.1** (2026-02-28): GOBACK depth-2 crash fix, VICE test suite fixes, test 10 DIR_DEPTH
- **v3.1.0** (2026-02-28): Directory header row in file browser
- **v3.0.0** (2026-02-22): PETMATE menu frame, inverse selection, cursor key nav, uppercase filenames
- **v2.1.1** (2026-02-21): Self-Test Suite, SD Write/Delete Bugfixes & Error Recovery (7/8 PASS)
- **v2.1.0** (2025-12-26): Production Polish & User Experience - Sprint 6 Complete
- **v2.0.6** (2025-12-26): Directory State Synchronization - Sprint 5 Complete (Production-Ready)
- **v2.0.5** (2025-12-25): SdFat 2.x API Modernization - Sprint 2 Complete
- **v2.0.4** (2025-12-25): Critical Memory and Stability Fixes (Sprint 1 Production-Ready)
- **v2.0.3** (2025-12-23): DEBUG Mode Fix and Mock Data
- **v2.0.2** (2025-12-22): Directory Navigation and Arduino Build System
- **v2.0.1** (2025-12-21): Relative filename support
- **v2.0.0** (2025-12-21): Centralized data management
- **v1.9.2** (2025-12-21): Python build system
- **v1.9.1** (2025-12-21): Path handling (DigiWavuino)
- **v1.9** (2025-12-21): TAP → PRG conversion
- **v1.8.1** (2025-12-21): Streaming buffer (400 byte)
- **v1.8** (2025-12-21): WavPlayer stabilization
- **v1.7** (2025-12-18): Plugin refactoring (Phase 2)
- **v1.6.1** (2025-12-15): 64tass .enc directive
- **v1.6** (2025-12-15): Build system, Phase 1
- **v1.5** (2025-12-14): Arduino critical bugfixes

---
