# VICE Automated Menu Test Suite

**Tool:** `Tools/test_vice_menu.py`
**Created:** 2026-02-21
**Requires:** VICE 3.9+ (x64sc), Python 3.10+

---

## Overview

Automated test suite that verifies C64 menu behavior by launching VICE in warp mode and interacting with the running program via VICE's binary monitor protocol (TCP). Tests menu navigation, directory entry, and screen rendering without manual interaction.

Analogous to `test_arduino_comm.py` (which tests Arduino firmware via serial), this tool tests the C64 side via emulation.

---

## Prerequisites

### VICE Emulator
- **Version:** 3.9 or later (binary monitor protocol v0x02)
- **Executable:** `x64sc.exe` (accurate SID/VIC emulation variant)
- **Default path:** `E:\Apps\GTK3VICE-3.9-win64\bin\x64sc.exe`
- Override with `--vice-path`

### Build Artifacts
The `debug-vice` build target must be run first to generate:
- `EasySD/build/easysd-debug.prg` — C64 menu program with mock data
- `EasySD/build/symbol/easysd.vs` — VICE-format symbol file

```powershell
python Tools/build.py debug-vice
```

Or use `--build` flag to build automatically before testing:
```powershell
python Tools/test_vice_menu.py --build
```

### Python
- Python 3.10+ (uses `int | None` type syntax)
- No external packages required (uses only stdlib: `socket`, `struct`, `subprocess`)

---

## Usage

```powershell
# Run all 10 tests
python Tools/test_vice_menu.py

# Build first, then test
python Tools/test_vice_menu.py --build

# Verbose output (monitor protocol traffic, memory reads)
python Tools/test_vice_menu.py --verbose

# Keep VICE open after tests for manual inspection
python Tools/test_vice_menu.py --keep-vice

# Custom VICE path
python Tools/test_vice_menu.py --vice-path "C:\VICE\bin\x64sc.exe"

# Custom binary monitor port (default: 6502)
python Tools/test_vice_menu.py --port 6510
```

### CLI Options

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--build` | `-b` | off | Run `debug-vice` build before testing |
| `--verbose` | `-v` | off | Show monitor protocol traffic and memory reads |
| `--keep-vice` | `-k` | off | Leave VICE open after tests complete |
| `--vice-path` | | `E:\Apps\GTK3VICE-3.9-win64\bin\x64sc.exe` | Path to x64sc executable |
| `--port` | `-p` | 6502 | TCP port for binary monitor |

---

## Test Cases

All tests run sequentially against a single VICE session with mock directory data (compiled into the `debug-vice` build).

### Mock Data Structure

The `debug-vice` build includes hardcoded mock directories:

**MOCK_DIR1 (root `/`, 5 items):**
| Row | Name | Type |
|-----|------|------|
| 0 | games | Directory |
| 1 | giana.prg | PRG |
| 2 | wizball.prg | PRG |
| 3 | sunset.koa | Koala image |
| 4 | logo.petg | PETSCII art |

**MOCK_DIR2 (`/games/`, 6 items):**
| Row | Name | Type |
|-----|------|------|
| 0 | .. | Parent dir |
| 1 | demos | Directory |
| 2 | music | Directory |
| 3 | bubble.prg | PRG |
| 4 | ocean.koa | Koala image |
| 5 | intro.petg | PETSCII art |

**MOCK_DIR3 (`/games/demos/`, 6 items):**
| Row | Name | Type |
|-----|------|------|
| 0 | .. | Parent dir |
| 1 | tools | Directory |
| 2 | matrix.prg | PRG |
| 3 | space.koa | Koala image |
| 4 | ascii.petg | PETSCII art |
| 5 | coder.wav | WAV audio |

### Test 1: INIT

Verifies initial menu state after boot:
- `CURPAGEITEMS` = 5 (root directory has 5 entries)
- `CURRENTROW` = 0 (cursor at top)
- `DIRLEVEL` = 0 (root level)
- `$D020` (border color) is logged for reference

### Test 2: NAV_DOWN

Injects DOWN key (PETSCII cursor down `$11`), verifies `CURRENTROW` increments by 1.

### Test 3: NAV_UP

Injects UP key (PETSCII cursor up `$91`), verifies `CURRENTROW` decrements by 1.

### Test 4: NAV_WRAP

Navigates cursor to row 0, then injects UP — verifies cursor wraps to `CURPAGEITEMS - 1` (bottom of list).

### Test 5: ENTER_DIR

Navigates to row 0 ("games" directory), injects ENTER:
- Polls `DIRLEVEL` until it changes from 0 to 1 (with timeout)
- `CURPAGEITEMS` changes from 5 to 6
- `$D020` (border color) increments (visual confirmation via `NEWCONTENT: INC BORDER`)

### Test 6: GO_BACK

Inside MOCK_DIR2, navigates to row 0 (".."), injects ENTER:
- Polls `DIRLEVEL` until it changes from 1 to 0 (with timeout)
- `CURPAGEITEMS` changes from 6 to 5

### Test 7: SCREEN_VERIFY

Navigates away from row 0 first (so `CLEARARROW` restores normal screen codes — `SETARROW` inverts characters on the selected row). Then reads screen RAM at `$0454` (first file entry row, below the directory header), verifies the screen codes match "games":

| Char | g | a | m | e | s |
|------|---|---|---|---|---|
| Code | 7 | 1 | 13 | 5 | 19 |

Screen codes: uppercase display in lc/uc charset mode — `PRINTASCIIFILENAME` maps ASCII letters to uppercase screen codes ($41-$5A). Reading after `CLEARARROW` ensures inverted bytes are restored to normal.

### Test 8: PRG_SELECT_ROOT

Selects a PRG file in the root directory and verifies the PROGRAM path:

1. Navigate to row 1 ("giana.prg")
2. Clear DEBUG sentinels (`$CF50-$CF52`)
3. Press ENTER
4. Poll `$CF51` (DEBUG_PRG_EXECUTED) until `$42` — mock PRG ran
5. Verify `$CF52` (DEBUG_PRG_SENTINEL) = `$DE`
6. Verify `$CF50` (DEBUG_PRG_REACHED) = `$01`
7. Read `PATHBUFFER` (`$033C`) — expect `/giana.prg`
8. Verify menu returned (CURRENTROW is readable)

### Test 9: PRG_SELECT_SUBDIR

Selects a PRG file inside a subdirectory and verifies the absolute path:

1. Enter `/games/` (ENTER on row 0, poll DIRLEVEL until 1)
2. Navigate to row 3 ("bubble.prg")
3. Clear DEBUG sentinels
4. Press ENTER
5. Poll `$CF51` until `$42`
6. Read `PATHBUFFER` — expect `/games/bubble.prg`
7. Verify menu returned
8. Go back to root (navigate to "..", ENTER, poll DIRLEVEL until 0)

**MOCK_PRG mechanism:**

In DEBUG mode, the PROGRAM path doesn't call `IRQ_InvokeWithName` (which requires Arduino). Instead, it copies a 13-byte mock PRG to `$C000` and executes it. The mock PRG:
- Sets sentinel values (`$42` at `$CF51`, `$DE` at `$CF52`)
- JMPs back to `INPUT_GET` (address patched at runtime)

This tests PATHBUFFER construction (SETFILENAME → BuildAbsolutePathFromPtr) without Arduino communication.

### Test 10: DIR_DEPTH

Multi-level navigation round-trip: root → `/games/` → `/games/demos/` → back.

1. Verify starting at root (`DIRLEVEL` = 0)
2. Navigate to row 0 ("games"), press ENTER, poll `DIRLEVEL` until 1
3. Read `CURRENTDIRINDEX` (expect 1)
4. Navigate to row 1 ("demos"), press ENTER, poll `DIRLEVEL` until 2
5. Read `CURRENTDIRINDEX` (expect 2), `CURPAGEITEMS` (expect 6)
6. Navigate back via `..` (`_go_up_one_level(1)`): poll `DIRLEVEL` until 1
7. Navigate back via `..` (`_go_up_one_level(0)`): poll `DIRLEVEL` until 0

Steps 6–7 are part of the pass/fail check — they verify `GOBACK` works correctly at depth 2. The `BCC ++` bug (fixed in v3.1.1) caused steps 6–7 to crash the menu: `GOBACK` jumps to the wrong label when the restore loop runs ≥1 iteration (i.e. depth ≥ 2).

`_go_up_one_level(expected)`: resumes C64, navigates to row 0 (`..`), resumes again, injects ENTER via keyboard buffer write while C64 is running, polls `DIRLEVEL` for `expected` with 5s timeout.

---

## Architecture

### Class Diagram

```
test_vice_menu.py
  |
  +-- ViceSymbols         Parse .vs label file -> symbol:address map
  |
  +-- ViceBinaryMonitor   TCP client for VICE binary monitor protocol
  |
  +-- ViceProcess         Launch/stop x64sc.exe subprocess
  |
  +-- ViceMenuTester      Test orchestrator (10 test cases)
```

### ViceSymbols

Parses 64tass `--vice-labels` output format:
```
al ba8 .TAP_SCAN_NO
al fdc .CURRENTROW
al 1ec0 .CURPAGEITEMS
```

Pattern: `al [C:]<hex> .<LABEL_NAME>` (1-6 hex digits, optional `C:` prefix)

Key method: `require(*names)` — returns address dict or raises `KeyError` for missing symbols.

### ViceBinaryMonitor

Implements VICE binary monitor protocol v0x02 over TCP.

**Wire format:**

Request (11-byte header + body):
```
[STX 0x02] [API 0x02] [body_len:u32le] [req_id:u32le] [cmd:u8] [body...]
```

Response (12-byte header + body):
```
[STX 0x02] [API 0x02] [body_len:u32le] [resp_type:u8] [err:u8] [req_id:u32le] [body...]
```

`body_len` counts only body bytes (excludes header).

**Commands used:**

| Code | Name | Purpose |
|------|------|---------|
| `0x01` | `memory_get` | Read C64 RAM (returns bytes at address range) |
| `0x02` | `memory_set` | Write bytes to C64 RAM (used for key injection) |
| `0x72` | `keyboard_feed` | Put keystrokes into VICE paste buffer (kept as fallback) |
| `0x81` | `ping` | Verify connection |
| `0xAA` | `exit` | Resume emulation (exit monitor/break state) |
| `0xBB` | `quit` | Terminate VICE |

**Important:** VICE enters "stopped" state when the binary monitor connects. Every `memory_get` also pauses emulation. The test framework calls `exit_monitor()` (CMD `0xAA`) after every interaction to resume the C64.

### ViceProcess

Launches VICE with:
```
x64sc.exe -binarymonitor -binarymonitoraddress ip4://127.0.0.1:6502
           +sound -warp -autostart <prg>
```

- **`-warp`**: Maximum speed (no frame rate limit) — C64 runs thousands of frames/second
- **`+sound`**: Disable sound (not needed for automated tests)
- **`-autostart`**: Automatically loads and runs the PRG
- **No `-moncommands`**: VICE treats label addresses as breakpoints, which would constantly stop emulation. Labels are parsed by `ViceSymbols` instead.

On Windows: uses `CREATE_NEW_PROCESS_GROUP` and `atexit` handler for cleanup.

### ViceMenuTester

Orchestrates test execution:
1. Launches VICE and waits for binary monitor connection (up to 10s, 20 retries)
2. Polls `CURPAGEITEMS` until non-zero (menu has loaded, ~3s intro screen + boot)
3. Runs all 10 tests sequentially
4. Reports PASS/FAIL with ANSI color output
5. Cleans up VICE (unless `--keep-vice`)

**Keyboard mapping** (menu uses KERNAL `GETIN`):

| Action | Key | PETSCII |
|--------|-----|---------|
| UP | Cursor up | 0x91 |
| DOWN | Cursor down | 0x11 |
| ENTER | Return | 0x0D |
| NEXT PAGE | `>` | 0x3E |
| PREV PAGE | `<` | 0x3C |

Note: v3.0.0 switched navigation from `+`/`-` ($2B/$2D) to cursor keys ($91/$11). Test suite updated in commit `691f784`.

---

## Key C64 Memory Addresses

These are read from the `.vs` symbol file at runtime:

| Symbol | Address | Description |
|--------|---------|-------------|
| `CURRENTROW` | (from .vs) | Currently selected row (0-based) |
| `CURPAGEITEMS` | (from .vs) | Number of items on current page |
| `DIRLEVEL` | (from .vs) | Directory depth (0=root, 1=subdir) |
| `DEBUG_PRG_REACHED` | `$CF50` | Set to `$01` when PROGRAM path entered |
| `DEBUG_PRG_EXECUTED` | `$CF51` | Set to `$42` by mock PRG execution |
| `DEBUG_PRG_SENTINEL` | `$CF52` | Set to `$DE` by mock PRG execution |

Addresses are resolved at runtime from the `.vs` symbol file (may change between builds).

Additional fixed addresses used:

| Address | Description |
|---------|-------------|
| `$0277` | C64 KERNAL keyboard buffer |
| `$00C6` | Keyboard buffer length |
| `$D020` | Border color (verified after directory changes) |
| `$033C` | PATHBUFFER — absolute path built by SETFILENAME |

Screen RAM layout (`COLS` table from `IrqLoaderMenuNew.s`):

| COLS index | Address | Content |
|------------|---------|---------|
| 0 | `$042C` | Header/title row |
| 1 | `$0454` | First file entry |
| 2 | `$047C` | Second file entry |
| ... | ... | ... |

---

## Key Injection

VICE's `keyboard_feed` command (CMD `0x72`) is unreliable when the emulator is in stopped state — keys may be lost because the paste buffer is not processed until VICE runs a frame.

Instead, the test writes directly to the C64 KERNAL keyboard buffer:

| Address | Description |
|---------|-------------|
| `$0277-$0280` | Keyboard buffer (10 bytes) |
| `$00C6` | Number of characters in buffer |

To inject a key press: write the PETSCII code to `$0277`, set `$00C6` to 1, then resume emulation. The C64's `GETIN` ($FFE4) reads from this buffer on the next main loop iteration.

## Synchronization Strategy

The test uses a hybrid approach — time-based delays for simple navigation, polling for state changes:

- **Boot wait**: Poll `CURPAGEITEMS` every 1s until non-zero (max 30s timeout)
- **Key settle**: 0.5s delay after each keystroke (C64 processes in warp mode)
- **Directory changes**: Poll `DIRLEVEL` for expected value with 0.3s intervals (max 5s timeout)
- **Resume cycle**: `_inject_key()` -> `exit_monitor()` -> `sleep()` -> `memory_get()`

In warp mode, the C64 executes thousands of frames per real-time second, so even 0.3s real-time delays give the emulated C64 hundreds of frames to process input.

Border color (`$D020`) is checked after directory changes as visual confirmation — the menu's `NEWCONTENT` routine increments it on every directory switch.

---

## Troubleshooting

### VICE not found
```
[ERR] VICE not found: E:\Apps\GTK3VICE-3.9-win64\bin\x64sc.exe
```
Install VICE 3.9+ and pass the correct path: `--vice-path "C:\path\to\x64sc.exe"`

### Connection timeout
```
[ERR] Could not connect to VICE monitor
```
- VICE may be slow to start. Increase retries in the connect logic if needed.
- Check that port 6502 is not in use by another process.
- Firewall may block localhost TCP connections.

### Menu load timeout
```
[ERR] Timeout waiting for menu to load
```
- The PRG may have failed to autostart. Run with `--keep-vice` to inspect the VICE window.
- Ensure `debug-vice` build was used (not `release` or `debug-arduino`).

### Tests fail intermittently
- The VICE binary monitor stop/resume cycle can cause timing issues.
- Try increasing `settle` delays in `_press_key()`.
- Run with `--verbose` to see exact monitor traffic.

### Black screen / frozen VICE
- VICE enters "stopped" state on binary monitor connect. The test framework resumes it automatically. If this fails, VICE appears frozen.
- Check `--verbose` output for connection errors.

### Visual appearance during testing
- VICE window may look choppy or show cursor jumping — this is normal. The binary monitor protocol pauses emulation on every `memory_get`, causing visible stuttering.
- Use `--keep-vice` to inspect the final state after all tests complete.

---

## Example Output

```
[INIT] Launching VICE...
[INIT] Connecting to binary monitor on port 6502...
[OK] VICE running, monitor connected

[INIT] Waiting for C64 menu to load...

============================================================
 EasySD VICE Menu Test Suite
============================================================

[1/10] INIT... PASS
[2/10] NAV_DOWN... PASS
[3/10] NAV_UP... PASS
[4/10] NAV_WRAP... PASS
[5/10] ENTER_DIR... PASS
[6/10] GO_BACK... PASS
[7/10] SCREEN_VERIFY... PASS
[8/10] PRG_SELECT_ROOT... PASS
[9/10] PRG_SELECT_SUBDIR... PASS
[10/10] DIR_DEPTH... PASS

============================================================
 ALL 10 TESTS PASSED
============================================================
```

---

## Related Files

| File | Purpose |
|------|---------|
| `Tools/test_vice_menu.py` | Test script (this document) |
| `Tools/build.py` | Build system (generates PRG + labels) |
| `EasySD/build/symbol/easysd.vs` | VICE-format symbol file |
| `EasySD/build/easysd-debug.prg` | Debug C64 binary with mock data |
| `EasySD/Menus/EasySD/EasySDMenu.s` | C64 menu source (mock data definitions) |
| `docs/build/BUILD_SYSTEM.md` | Build system documentation |
| `Tools/test_arduino_comm.py` | Arduino serial test suite (similar pattern) |
