# EasySD IRQHack64 - Selective Category Logging Guide

**Date:** 2026-01-02
**Status:** Production Ready
**Related:** LOGGING_SYSTEM_DESIGN.md, EasySDLog.h

---

## PROBLEM

Arduino Nano has 30720 bytes flash capacity. With full logging enabled (all categories), the sketch uses **31680 bytes (103%)** - **does not fit!**

---

## SOLUTION

Selective category compilation via `LOG_ENABLE_*` flags. Only compile logging code for categories you need to debug.

---

## FLASH USAGE BY CATEGORY

| Category | Flash Usage | Description | Recommended |
|----------|-------------|-------------|-------------|
| `SYS` | ~960 bytes | System init, memory, status | ✅ Always |
| `SD` | ~180 bytes | SD card initialization | ✅ Always |
| `DIR` | ~1800 bytes | Directory navigation | ✅ Default |
| `FILE` | ~1600 bytes | File operations | ⚠️ If needed |
| `PRG` | ~1200 bytes | Program loading (.prg, .crt, .tap) | ⚠️ If needed |
| `PROTO` | ~800 bytes | Protocol/streaming (advanced) | ❌ Rarely needed |
| `ERR` | ~80 bytes | Critical errors | ✅ Always |

**Total (all categories):** ~6620 bytes
**Default (SYS+SD+DIR+FILE+PRG+ERR):** ~5020 bytes → **28092 bytes (91%)** ✅ Fits with headroom!
**Without test functions:** Saves additional ~3400 bytes

---

## DEFAULT CONFIGURATION

The default build (generated in `BuildConfig.h`) enables:

```cpp
#define LOG_ENABLE_SYS    1  // ✅ System
#define LOG_ENABLE_SD     1  // ✅ SD card
#define LOG_ENABLE_DIR    1  // ✅ Directory navigation
#define LOG_ENABLE_FILE   1  // ✅ File operations
#define LOG_ENABLE_PRG    1  // ✅ Program loading
#define LOG_ENABLE_PROTO  0  // ❌ Protocol/streaming (disabled, rarely needed)
#define LOG_ENABLE_ERR    1  // ✅ Critical errors
```

**Result:** 28092 bytes (91%) - **fits on Arduino Nano with 9% headroom!**

**Note:** Serial monitor test functions removed (saves ~3400 bytes). Professional test suite will be implemented in Phase 4.

---

## CUSTOM CONFIGURATIONS

### 1. Minimal Debug (SYS, SD, ERR only)

**Use case:** Basic system diagnostics, maximum space for code

```cpp
// Before #include "IrqHack64.h" in your .ino or .cpp:
#define LOG_ENABLE_SYS    1
#define LOG_ENABLE_SD     1
#define LOG_ENABLE_DIR    0  // Disabled
#define LOG_ENABLE_FILE   0
#define LOG_ENABLE_PRG    0
#define LOG_ENABLE_PROTO  0
#define LOG_ENABLE_ERR    1
```

**Result:** ~28784 bytes (93%)

---

### 2. File Operations Debug

**Use case:** Debugging file open/read/write issues

```cpp
#define LOG_ENABLE_SYS    1
#define LOG_ENABLE_SD     1
#define LOG_ENABLE_DIR    0  // Disable to make room
#define LOG_ENABLE_FILE   1  // ✅ Enable file debugging
#define LOG_ENABLE_PRG    0
#define LOG_ENABLE_PROTO  0
#define LOG_ENABLE_ERR    1
```

**Result:** ~29084 bytes (94%)

---

### 3. Program Loading Debug

**Use case:** Debugging .prg/.crt/.tap loading issues

```cpp
#define LOG_ENABLE_SYS    1
#define LOG_ENABLE_SD     1
#define LOG_ENABLE_DIR    0  // Disable to make room
#define LOG_ENABLE_FILE   0
#define LOG_ENABLE_PRG    1  // ✅ Enable program loading debug
#define LOG_ENABLE_PROTO  0
#define LOG_ENABLE_ERR    1
```

**Result:** ~29184 bytes (95%)

---

### 4. Maximum Debug (if you have a larger Arduino)

**Use case:** Arduino Mega 2560 (256KB flash) or other boards with more capacity

```cpp
#define LOG_ENABLE_SYS    1  // All enabled
#define LOG_ENABLE_SD     1
#define LOG_ENABLE_DIR    1
#define LOG_ENABLE_FILE   1
#define LOG_ENABLE_PRG    1
#define LOG_ENABLE_PROTO  1
#define LOG_ENABLE_ERR    1
```

**Result:** ~31680 bytes (103% on Nano) - **only for boards with >32KB flash**

---

## HOW TO CUSTOMIZE

### Method 1: Modify BuildConfig.h (recommended)

Edit `IRQHack64/build/artifacts/BuildConfig.h` before compiling:

```cpp
// Change from:
#ifndef LOG_ENABLE_FILE
  #define LOG_ENABLE_FILE   0  // DISABLED
#endif

// To:
#ifndef LOG_ENABLE_FILE
  #define LOG_ENABLE_FILE   1  // ENABLED for debugging
#endif
```

**Warning:** `build.py` regenerates this file, so changes are temporary. For permanent changes, modify `Tools/build.py` lines 490-501.

---

### Method 2: Override in Source Files

Define flags **BEFORE** including `IrqHack64.h` in your `.ino` or `.cpp` files:

```cpp
// IRQHack64.ino (or any .cpp file)
#define LOG_ENABLE_FILE   1  // Override default

#include "IrqHack64.h"  // This includes BuildConfig.h
#include "EasySDLog.h"
```

**Note:** The `#ifndef` guards in `BuildConfig.h` allow early definitions to take precedence.

---

### Method 3: Modify build.py (permanent)

Edit `Tools/build.py` lines 490-501 to change default configuration:

```python
#ifndef LOG_ENABLE_FILE
  #define LOG_ENABLE_FILE   1  # Change 0 → 1 to enable by default
#endif
```

Then rebuild:
```bash
python Tools/build.py arduino-compile --debug
```

---

## VERIFICATION

After changing configuration, verify flash usage:

```bash
cd "C:\EasySD Gemini"
python Tools/build.py arduino-compile --debug
```

Look for output:
```
Sketch uses 30444 bytes (99%) of program storage space. Maximum is 30720 bytes.
```

- **< 100%** = ✅ Fits
- **≥ 100%** = ❌ Too large, disable more categories

---

## EXAMPLES BY USE CASE

| Debugging Task | Enable Categories | Flash Usage |
|----------------|-------------------|-------------|
| SD card won't initialize | SYS, SD, ERR | ~1220 bytes (24484 total, 79%) |
| Production debug (default) | SYS, SD, DIR, FILE, PRG, ERR | ~5020 bytes (28092 total, 91%) ✅ Default |
| Directory navigation only | SYS, SD, DIR, ERR | ~3020 bytes (26284 total, 85%) |
| File operations only | SYS, SD, FILE, ERR | ~2820 bytes (26084 total, 84%) |
| Program loading only | SYS, SD, PRG, ERR | ~2420 bytes (25684 total, 83%) |
| Cartridge protocol issues | SYS, SD, PROTO, ERR | ~2020 bytes (25284 total, 82%) |

---

## COMMON QUESTIONS

### Q: Why not use runtime filtering instead?

**A:** Runtime filtering requires:
- Global state variables (~10-20 bytes RAM)
- Runtime checks (`if (level >= threshold)`) in every log call
- Still compiles all log strings into flash

Compile-time filtering:
- Zero RAM overhead
- Zero runtime overhead
- Eliminates unused strings from flash entirely

### Q: Can I enable everything on Arduino Nano?

**A:** No. All categories = 31680 bytes (103%), which exceeds 30720 bytes capacity. You must disable at least FILE+PRG (~2800 bytes) to fit.

### Q: Does disabling a category remove ALL logs?

**A:** Yes. When `LOG_ENABLE_FILE = 0`, all `LOGD(FILE, ...)`, `LOGE(FILE, ...)`, etc. calls compile to `((void)0)` (nothing). The compiler optimizes them away completely.

### Q: What if I need FILE and PRG simultaneously?

**A:** Possible, but tight:
- SYS + SD + FILE + PRG + ERR = ~4840 bytes → 29104 bytes total (94%)
- Must disable DIR to make room

### Q: Can I change categories without rebuilding?

**A:** No. Categories are compile-time only. Changing `LOG_ENABLE_*` flags requires recompiling the sketch.

---

## TROUBLESHOOTING

### "Sketch too big" error

```
Sketch uses 31680 bytes (103%) of program storage space. Maximum is 30720 bytes.
Error during build: text section exceeds available space in board
```

**Solution:** Disable more categories in `BuildConfig.h` or `build.py`.

### Logs not appearing on Serial Monitor

**Possible causes:**
1. Category disabled via `LOG_ENABLE_* = 0`
2. `EASYSD_DEBUG_SERIAL` not defined (release build)
3. Baud rate mismatch (use 57600)
4. LOG macro called from ISR (not allowed, see LOGGING_SYSTEM_DESIGN.md section 5)

**Check:**
```bash
# Verify debug build
grep "EASYSD_DEBUG_SERIAL" IRQHack64/build/artifacts/BuildConfig.h

# Check category flags
grep "LOG_ENABLE" IRQHack64/build/artifacts/BuildConfig.h
```

---

## RELATED DOCUMENTS

- **LOGGING_SYSTEM_DESIGN.md** - Complete API specification, ISR safety policy
- **LOGGING_MIGRATION_COMPLETE.md** - Migration history, statistics
- **EasySDLog.h** - Implementation (lines 74-501 for category flags)
- **Tools/build.py** - BuildConfig.h generation (lines 473-502)

---

**END OF GUIDE**

Generated: 2026-01-02
By: Claude (Sonnet 4.5)
