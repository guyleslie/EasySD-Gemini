# Protocol Echo Test Mode

Serial protocol echo test for the EasySD Arduino firmware.
Redirects SD file data to `Serial.write()` so a PC can verify byte-level correctness
of SD reads and game-header calculations without needing a real C64.

---

## Purpose

The Arduino serves data to the C64 via four transfer mechanisms:
- NMI fast transfer (~40 KB/s)
- IO2 double-buffer streaming (~13.5 KB/s)
- NI burst
- Game launch header (10-byte struct)

These are hard to test without real C64 hardware.
Protocol echo test mode redirects file data and header computations to the serial
port so a PC-side script can verify them byte-by-byte.

---

## Build Target

```bash
# Compile only (check size)
python Tools/build.py protocol-test

# Compile + upload
python Tools/build.py protocol-test COM4
```

The `protocol-test` target writes a special `BuildConfig.h`:

```cpp
#define EASYSD_DEBUG_SERIAL
#define EASYSD_PROTOCOL_TEST
#define LOG_ENABLE_DIR 0    // ~400B flash saving
#define LOG_ENABLE_FILE 0   // ~200B flash saving
```

`LOG_ENABLE_DIR/FILE` are disabled to reclaim ~600 B of flash headroom, making room
for the ~800 B of new test functions while staying within the 30 720 B flash limit.

> **Note:** The NI stream (`COMMAND_NI_STREAM`) is NOT testable in this mode — its
> tight polling loop (`noInterrupts()` + direct PORT writes) cannot be redirected to
> Serial without a full rework. The file dump tests cover the same SD read path.

---

## Serial Commands

All three commands require `EASYSD_PROTOCOL_TEST` firmware.
Send command byte immediately followed by filename + `\n`.

| Cmd | Function         | What it tests                                      |
|-----|------------------|----------------------------------------------------|
| `F` | File dump        | SD reads; all bytes of a file over Serial          |
| `G` | Game header      | `TransferGame()` header calculation + P2TK trigger |
| `B` | Boundary dump    | 64 B chunk read boundaries                         |

### F — File Dump

```
Send:    b'F' + filename.encode() + b'\n'
Receive: "[FD] SIZE=N\r\n"
         <N raw binary bytes>
         "[FD] END\r\n"
```

Dumps the entire file as raw bytes over Serial, prefixed by its size.
The Python parser uses `serial.read(N)` (length-based) to consume the binary payload
so `\n` bytes inside the file data do not interfere with line framing.

### G — Game Header

```
Send:    b'G' + filename.encode() + b'\n'
Receive: "[GH] LOAD=$XXXX END=$XXXX PAGES=N TYPE=1 SIZE=N P2TK=Y/N\r\n"
```

Mirrors `TransferGame()` + `SendHeader()` logic in `CartApi.cpp`:

| Field   | Source                                                             |
|---------|--------------------------------------------------------------------|
| `LOAD`  | First 2 bytes of PRG (little-endian load address)                 |
| `END`   | `startAddr + (fileSize - 2) + 1`                                  |
| `PAGES` | `ceil((fileSize-2) / 256)`                                        |
| `TYPE`  | Always `1` (TYPE_STANDARD_PRG) — test files are plain PRGs        |
| `SIZE`  | `f.size()` (total file bytes incl. 2-byte header)                 |
| `P2TK`  | `Y` if `endAddress > $C002` (KernalBridge Phase 2 trigger)        |

### B — Boundary Dump

```
Send:    b'B' + filename.encode() + b'\n'
Receive: "[BD] CHUNK=0 SZ=64\r\n"
         <64 raw binary bytes>
         "[BD] CHUNK=1 SZ=64\r\n"
         <64 raw binary bytes>
         ...
         "[BD] END\r\n"
```

Reads the file in 64 B chunks (matching `DOUBLE_BUFFER_SIZE` in `CartApi.h`).
Each chunk is prefixed with its index and byte count.
The Python parser uses `serial.read(SZ)` for each chunk so binary `\n` bytes
within the payload do not corrupt framing.

---

## Python Test Runner

```bash
# All 5 protocol tests
python Tools/test_arduino_comm.py COM4 --test protocol

# Individual test groups
python Tools/test_arduino_comm.py COM4 --test file_dump
python Tools/test_arduino_comm.py COM4 --test game_header
python Tools/test_arduino_comm.py COM4 --test boundary_dump
```

### Test Suite (`--test protocol`)

| # | Test                       | Expected                                       |
|---|----------------------------|------------------------------------------------|
| 1 | File dump: TESTDATA.BIN    | 256/256 bytes match `bytes(range(256))`        |
| 2 | File dump: BIGFILE.BIN     | 2048/2048 bytes match `bytes(range(256)) * 8`  |
| 3 | Game header: TESTPRG.PRG   | `LOAD=$0801, PAGES=1, P2TK=N`                  |
| 4 | Game header: HIGHPRG.PRG   | `LOAD=$C000, PAGES=1, P2TK=Y`                  |
| 5 | Boundary dump: BIGFILE.BIN | 2048/2048 bytes, 32 chunks of 64 B             |

The boundary dump also reports whether a mismatch falls near a 64 B chunk boundary
(`BOUNDARY BUG`) or in the middle of a chunk (`offset N/64`).

---

## SD Card Test Files

Prepare with:

```bash
python Tools/prepare_test_sd.py D:
```

Files added by this feature (in addition to the standard test files):

| File          | Content                                    | Purpose                     |
|---------------|--------------------------------------------|-----------------------------|
| `TESTPRG.PRG` | `\x01\x08` + `bytes(range(100))` (102 B)  | Standard PRG, P2TK=N check  |
| `HIGHPRG.PRG` | `\x00\xC0` + `bytes(range(100))` (102 B)  | High PRG, P2TK=Y check       |

**TESTPRG.PRG** calculations:
- Load address: `$0801`
- `endAddress = $0801 + 100 + 1 = $0866` → P2TK=N ✓

**HIGHPRG.PRG** calculations:
- Load address: `$C000`
- `endAddress = $C000 + 100 + 1 = $C065 > $C002` → P2TK=Y ✓

---

## Full Workflow

```bash
# 1. Prepare SD card (one-time)
python Tools/prepare_test_sd.py D:

# 2. Build + upload protocol-test firmware
python Tools/build.py protocol-test COM4

# 3. Run all protocol tests
python Tools/test_arduino_comm.py COM4 --test protocol --verbose
```

Expected output:
```
  PASS  TESTDATA.BIN: 256/256 bytes match
  PASS  BIGFILE.BIN: 2048/2048 bytes match
  PASS  TESTPRG.PRG: header OK
  PASS  HIGHPRG.PRG: header OK
  PASS  BIGFILE.BIN: 2048/2048 bytes match, 32 chunks

 ALL 5 PROTOCOL TESTS PASSED
```

---

## Implementation Notes

- `ptReadFilename()` in `EasySD.ino`: blocks until `\n`/`\r` or 12-char limit.
  Filename sent as `b'<CMD><NAME>\n'` — command char consumed by `loop()` switch,
  name read by the test function.
- Flash budget: protocol-test build adds ~800 B (3 functions) but disables
  `LOG_ENABLE_DIR` + `LOG_ENABLE_FILE` saving ~600 B, net ~+200 B vs debug build.
- Local variable budget: all 3 functions use `char name[13]` + `uint8_t buf[16]`
  = ~40 B stack per function, well within the 300 B free-stack minimum.
- `testBoundaryDump` uses a 16 B read buffer and tracks 64 B chunk boundaries with
  a counter, avoiding a 64 B stack buffer while testing the same SD read path.
