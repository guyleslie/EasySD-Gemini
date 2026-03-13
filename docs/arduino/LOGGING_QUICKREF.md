# EasySD Arduino Logging — Quick Reference

**File:** `Arduino/EasySD/EasySDLog.h`
**Active since:** Sprint 12 (2026-03-03)

---

## How to Read the Log Output

Connect Arduino via USB at **57600 baud** (Arduino IDE Serial Monitor, or `python Tools/test_arduino_comm.py COM4`).

Log lines have the format:

```
[LEVEL][CATEGORY] message
```

| Level  | Meaning |
|--------|---------|
| `ERR ` | Error — something failed |
| `WARN` | Warning — degraded state |
| `INFO` | Key state change (SD OK, file opened, dir changed) |
| `DBG ` | Entry point / operation detail |
| `TRC ` | Very verbose trace (rarely used) |

| Category | What it covers |
|----------|---------------|
| `SYS`  | Startup, EEPROM, general system events |
| `SD`   | SD card init and recovery |
| `DIR`  | Directory navigation (chdir, iterate, prepare) |
| `FILE` | File open/read/write/close/seek |
| `PRG`  | Program/TAP/CRT loading |
| `PROTO`| Byte-level cartridge protocol |
| `ERR`  | Critical errors (separate category for routing) |

**Example output:**
```
[INFO][SYS] EasySD v2.1.0
[INFO][SD]  SD OK
[INFO][DIR] Changed to ROOT
[DBG ][DIR] Prepare: / n=5
[DBG ][FILE] HandleOpenFile
[DBG ][FILE] fn: HELLO.PRG
[INFO][FILE] File opened successfully
[ERR ][SD]  SD recover FAIL
```

Self-test lines always start with `[T]` and are not affected by category settings:
```
[T] START
[T] OPEN_RD_CL: PASS
[T] END: 7/8 RAM:415->415
```

---

## Enable / Disable Categories (Flash Optimization)

The Arduino Nano has only 30720 bytes of flash. All categories enabled at once exceeds the limit.

**Default (in `EasySDLog.h`):** SYS + SD + DIR + FILE + ERR are ON. PRG and PROTO are OFF.

```
Debug build size: 30248 bytes (98%) — 472 bytes free
Release build:    22714 bytes (73%) — no logging compiled in
```

To override, define flags **before** the `#include "EasySDLog.h"` line in your .ino or .cpp:

```cpp
#define LOG_ENABLE_PRG   1   // turn on program loading logs
#define LOG_ENABLE_PROTO 1   // turn on protocol logs (warning: verbose!)
#define LOG_ENABLE_DIR   0   // turn off directory logs to save ~1800 bytes
#include "EasySDLog.h"
```

**Minimal build (errors only, ~22800 bytes total):**
```cpp
#define LOG_ENABLE_SYS   0
#define LOG_ENABLE_SD    0
#define LOG_ENABLE_DIR   0
#define LOG_ENABLE_FILE  0
#define LOG_ENABLE_ERR   1
```

---

## API — How to Add Log Statements

```cpp
// Categorized messages (string literal only — auto-wrapped in F())
LOGE(SD,   "SD recover FAIL");      // [ERR ][SD]  SD recover FAIL
LOGW(DIR,  "GoBack: at ROOT");      // [WARN][DIR] GoBack: at ROOT
LOGI(DIR,  "Changed to ROOT");      // [INFO][DIR] Changed to ROOT
LOGD(FILE, "HandleOpenFile");       // [DBG ][FILE] HandleOpenFile

// Variable output (not category-gated — always compiles in debug mode)
LOG_PRINT_F("path: ");              // Serial.print(F("path: "))
LOG_PRINTLN(dirFunc.currentPath);   // Serial.println(variable)
LOG_PRINTLN_F("done");              // Serial.println(F("done"))
LOG_HEX(errorCode);                 // Serial.print(errorCode, HEX)
LOG_NEWLINE();                      // Serial.println()

// Initialization (call once in setup())
LOG_BEGIN(57600);
```

**Category tokens:** `SYS`, `SD`, `DIR`, `FILE`, `PRG`, `PROTO`, `ERR`

---

## ISR Safety — CRITICAL

**Never call any LOG macro from an ISR or ISR-reachable code.**
Serial.print inside an ISR causes crashes. Use volatile counters instead:

```cpp
volatile uint8_t g_isr_count = 0;   // in ISR: g_isr_count++;
// in loop(): LOGD(PROTO, "ISR events: "); LOG_PRINTLN(g_isr_count);
```

---

## Release Builds

In release builds (`EASYSD_DEBUG_SERIAL` not defined), all LOG macros compile to `((void)0)` — zero flash, zero RAM, zero overhead. The Serial library is not linked.

---

## Related Files

| File | Purpose |
|------|---------|
| `Arduino/EasySD/EasySDLog.h` | The logging header (single source of truth) |
| `Arduino/EasySD/DebugLog.h` | Old system — deprecated, do not use for new code |
| `docs/arduino/LOGGING_SYSTEM_DESIGN.md` | Full design specification |
| `docs/arduino/LOGGING_SELECTIVE_CATEGORIES.md` | Flash optimization guide |
| `docs/arduino/LOGGING_MIGRATION_COMPLETE.md` | Migration history and rationale |
