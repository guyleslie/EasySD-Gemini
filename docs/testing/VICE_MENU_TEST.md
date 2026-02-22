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
- `IRQHack64/build/irqhack64-debug.prg` — C64 menu program with mock data
- `IRQHack64/build/symbol/IrqLoaderMenuNew.vs` — VICE-format symbol file

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
# Run all 7 tests
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

**DIR1 (root, 5 items):**
| Row | Name | Type |
|-----|------|------|
| 0 | merhaba | Directory |
| 1 | televole | File |
| 2 | hello.prg | PRG |
| 3 | africa.koa | KOA |
| 4 | guzel.petg | PETG |

**DIR2 (inside merhaba, 6 items):**
| Row | Name | Type |
|-----|------|------|
| 0 | .. | Parent dir |
| 1 | deneme1 | Directory |
| 2 | deneme2 | Directory |
| 3 | firzt.prg | PRG |
| 4 | latina.koa | KOA |
| 5 | spell.petg | PETG |

### Test 1: INIT

Verifies initial menu state after boot:
- Debug sentinel at `$CF41` = `$42DE` (non-fatal if missing)
- `CURPAGEITEMS` = 5 (root directory has 5 entries)
- `CURRENTROW` = 0 (cursor at top)
- `DIRLEVEL` = 0 (root level)

### Test 2: NAV_DOWN

Presses DOWN key (`-`), verifies `CURRENTROW` increments by 1.

### Test 3: NAV_UP

Presses UP key (`+`), verifies `CURRENTROW` decrements by 1.

### Test 4: NAV_WRAP

Navigates cursor to row 0, then presses UP — verifies cursor wraps to `CURPAGEITEMS - 1` (bottom of list).

### Test 5: ENTER_DIR

Navigates to row 0 ("merhaba" directory), presses ENTER:
- `DIRLEVEL` changes from 0 to 1
- `CURPAGEITEMS` changes from 5 to 6

### Test 6: GO_BACK

Inside DIR2, navigates to row 0 (".."), presses ENTER:
- `DIRLEVEL` changes from 1 to 0
- `CURPAGEITEMS` changes from 6 to 5

### Test 7: SCREEN_VERIFY

Reads screen RAM at `$0454` (first file entry row), verifies the screen codes match "merhaba":

| Char | m | e | r | h | a | b | a |
|------|---|---|---|---|---|---|---|
| Code | 13 | 5 | 18 | 8 | 1 | 2 | 1 |

Screen codes: lowercase `a`=1, `b`=2, ..., `z`=26.

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
  +-- ViceMenuTester      Test orchestrator (7 test cases)
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
| `0x72` | `keyboard_feed` | Put keystrokes into VICE keyboard buffer |
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
3. Runs all 7 tests sequentially
4. Reports PASS/FAIL with ANSI color output
5. Cleans up VICE (unless `--keep-vice`)

**Keyboard mapping** (menu uses KERNAL `GETIN`):

| Action | Key | ASCII |
|--------|-----|-------|
| UP | `+` | 0x2B |
| DOWN | `-` | 0x2D |
| ENTER | `\r` | 0x0D |
| NEXT PAGE | `.` | 0x2E |
| PREV PAGE | `,` | 0x2C |

---

## Key C64 Memory Addresses

These are read from the `.vs` symbol file at runtime:

| Symbol | Address | Description |
|--------|---------|-------------|
| `CURRENTROW` | `$0FDC` | Currently selected row (0-based) |
| `CURPAGEITEMS` | `$1EC0` | Number of items on current page |
| `DIRLEVEL` | `$2914` | Directory depth (0=root, 1=subdir) |
| `DEBUG_MAGIC` | `$CF41` | Debug sentinel (`$42DE` when debug active) |

Screen RAM layout (`COLS` table from `IrqLoaderMenuNew.s`):

| COLS index | Address | Content |
|------------|---------|---------|
| 0 | `$042C` | Header/title row |
| 1 | `$0454` | First file entry |
| 2 | `$047C` | Second file entry |
| ... | ... | ... |

---

## Synchronization Strategy

The test uses time-based synchronization rather than polling specific memory flags:

- **Boot wait**: Poll `CURPAGEITEMS` every 1s until non-zero (max 30s timeout)
- **Key settle**: 0.3s delay after each keystroke (0.1s for rapid navigation, 0.5s for Enter)
- **Resume cycle**: `keyboard_feed()` -> `exit_monitor()` -> `sleep()` -> `memory_get()`

In warp mode, the C64 executes thousands of frames per real-time second, so even 0.1s real-time delays give the emulated C64 hundreds of frames to process input.

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

[1/7] INIT... PASS
[2/7] NAV_DOWN... PASS
[3/7] NAV_UP... PASS
[4/7] NAV_WRAP... PASS
[5/7] ENTER_DIR... PASS
[6/7] GO_BACK... PASS
[7/7] SCREEN_VERIFY... PASS

============================================================
 ALL 7 TESTS PASSED
============================================================
```

---

## Related Files

| File | Purpose |
|------|---------|
| `Tools/test_vice_menu.py` | Test script (this document) |
| `Tools/build.py` | Build system (generates PRG + labels) |
| `IRQHack64/build/symbol/IrqLoaderMenuNew.vs` | VICE-format symbol file |
| `IRQHack64/build/irqhack64-debug.prg` | Debug C64 binary with mock data |
| `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s` | C64 menu source (mock data definitions) |
| `docs/build/BUILD_SYSTEM.md` | Build system documentation |
| `Tools/test_arduino_comm.py` | Arduino serial test suite (similar pattern) |
