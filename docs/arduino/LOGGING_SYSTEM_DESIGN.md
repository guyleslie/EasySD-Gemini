# EasySD IRQHack64 - Logging System Design v2.0

**Status:** Design Specification
**Date:** 2026-01-01
**Author:** Claude (Phase 2)

---

## 1. DESIGN GOALS

### Primary Objectives
1. **ISR Safety** - Zero Serial output from ISR or ISR-reachable code paths
2. **Zero Overhead** - Release builds compile to nothing (no runtime cost)
3. **Categorization** - Structured logging by subsystem
4. **Clarity** - Clean API, no legacy baggage, no ambiguity
5. **Simplicity** - Minimal global state, compile-time gating only

### Non-Goals
- Backwards compatibility with DBG_* macros (clean break)
- Runtime filtering (adds complexity, state overhead)
- Log buffering (adds memory pressure on 2KB SRAM)
- Multiple output targets (Serial only)

---

## 2. CATEGORIES

Logging is organized by subsystem:

| Category | Symbol   | Purpose |
|----------|----------|---------|
| System   | `SYS`    | Init, reset, mode changes, memory diagnostics |
| SD Card  | `SD`     | Card init, mount, card detection |
| Directory| `DIR`    | Navigation, chdir, iteration |
| File     | `FILE`   | Open, read, write, close, seek |
| Protocol | `PROTO`  | Cartridge interface, byte transmission, ISR events |
| Program  | `PRG`    | .prg/.crt/.tap loading, conversion |
| Error    | `ERR`    | Critical failures (always enabled) |

### 2.1 Selective Category Enabling (Flash Size Optimization)

**Problem:** Full logging (all categories) uses ~6600 bytes of flash, which exceeds Arduino Nano capacity (30720 bytes total, ~5600 bytes available).

**Solution:** Selective category compilation via `LOG_ENABLE_*` flags.

**Flash Usage Estimates:**

| Category | Flash Usage | Typical Use Case |
|----------|-------------|------------------|
| `LOG_ENABLE_SYS` | ~960 bytes | System init, memory diagnostics |
| `LOG_ENABLE_SD` | ~180 bytes | SD card initialization |
| `LOG_ENABLE_DIR` | ~1800 bytes | Directory navigation debugging |
| `LOG_ENABLE_FILE` | ~1600 bytes | File operation debugging |
| `LOG_ENABLE_PRG` | ~1200 bytes | Program loading debugging |
| `LOG_ENABLE_PROTO` | ~800 bytes | Protocol/streaming debugging |
| `LOG_ENABLE_ERR` | ~80 bytes | Critical errors (always recommended) |

**Default Configuration (in BuildConfig.h):**
```cpp
#define LOG_ENABLE_SYS    1  // Enabled
#define LOG_ENABLE_SD     1  // Enabled
#define LOG_ENABLE_DIR    1  // Enabled
#define LOG_ENABLE_FILE   1  // Enabled
#define LOG_ENABLE_PRG    1  // Enabled
#define LOG_ENABLE_PROTO  0  // DISABLED (saves ~800 bytes, rarely needed)
#define LOG_ENABLE_ERR    1  // Enabled (always recommended)
```

**Result:** ~28092 bytes (91% of Nano capacity) - fits with 9% headroom!

**Note:** Serial monitor test functions removed (saves ~3400 bytes). Professional test suite will be implemented in Phase 4.

**Custom Configuration:**

To enable specific categories for debugging, modify the flags **BEFORE** including EasySDLog.h:

```cpp
// Example: Debug file operations only
#define LOG_ENABLE_SYS    1
#define LOG_ENABLE_SD     1
#define LOG_ENABLE_DIR    0  // Disable to save space
#define LOG_ENABLE_FILE   1  // Enable for file debugging
#define LOG_ENABLE_PRG    0
#define LOG_ENABLE_PROTO  0
#define LOG_ENABLE_ERR    1

#include "IrqHack64.h"  // Includes BuildConfig.h
#include "EasySDLog.h"
```

**Note:** The `#ifndef` guards in BuildConfig.h allow you to override defaults before the include.

---

## 3. LOG LEVELS

| Level   | Symbol  | Priority | Usage |
|---------|---------|----------|-------|
| Error   | `ERROR` | 0        | Critical failures, must investigate |
| Warning | `WARN`  | 1        | Non-critical issues, degraded operation |
| Info    | `INFO`  | 2        | Normal operation messages |
| Debug   | `DEBUG` | 3        | Development diagnostics |
| Trace   | `TRACE` | 4        | Very verbose (byte-level protocol) |

**Compile-time filtering only** - no runtime level checking.

---

## 4. API SPECIFICATION

### 4.1 Initialization

```cpp
LOG_BEGIN(baud)
```

**Purpose:** Initialize Serial interface
**Parameters:** `baud` - Baud rate (typically 57600)
**Usage:** Call once in `setup()`
**Example:**
```cpp
void setup() {
  LOG_BEGIN(57600);
}
```

---

### 4.2 Categorized Logging

```cpp
LOGE(category, message)  // Error level
LOGW(category, message)  // Warning level
LOGI(category, message)  // Info level
LOGD(category, message)  // Debug level
LOGT(category, message)  // Trace level (optional)
```

**Purpose:** Log a constant string message with category and level
**Parameters:**
- `category` - One of: SYS, SD, DIR, FILE, PROTO, PRG, ERR
- `message` - String literal (will be wrapped in F() macro)

**Output Format:**
```
[LEVEL][CATEGORY] message
```

**Examples:**
```cpp
LOGI(SYS, "System initialized");
// Output: [INFO][SYS] System initialized

LOGE(SD, "Card init failed");
// Output: [ERR ][SD] Card init failed

LOGD(DIR, "Entering directory");
// Output: [DBG ][DIR] Entering directory

LOGT(PROTO, "Byte transmitted");
// Output: [TRC ][PROTO] Byte transmitted
```

**Rules:**
- Message MUST be a string literal (not a variable)
- Message is automatically stored in PROGMEM (F() macro)
- Use LOG_PRINT/LOG_PRINTLN for variable output

---

### 4.3 Variable Output

```cpp
LOG_PRINT(x)        // Print value without newline
LOG_PRINTLN(x)      // Print value with newline
LOG_PRINT_F(msg)    // Print F() string without newline
LOG_PRINTLN_F(msg)  // Print F() string with newline
LOG_HEX(x)          // Print as hexadecimal
LOG_DEC(x)          // Print as decimal
LOG_NEWLINE()       // Print newline only
```

**Purpose:** Output variables, expressions, or formatted values
**Usage:** Chain with categorized macros for complete messages

**Examples:**
```cpp
LOGI(SYS, "Free RAM: ");
LOG_PRINTLN(FreeStack());
// Output: [INFO][SYS] Free RAM:
//         1234

LOGD(FILE, "Opening: ");
LOG_PRINTLN(filename);
// Output: [DBG ][FILE] Opening:
//         GAME.PRG

LOGT(PROTO, "TX: 0x");
LOG_HEX(byte);
LOG_NEWLINE();
// Output: [TRC ][PROTO] TX: 0x
//         A9
```

---

### 4.4 Utilities

```cpp
LOG_HEADER(title)    // Print boxed header
LOG_SEPARATOR()      // Print separator line
```

**Purpose:** Structured output formatting

**Examples:**
```cpp
LOG_HEADER("System Status");
// Output:
// ====================================
// == System Status ==
// ====================================

LOG_SEPARATOR();
// Output:
// ------------------------------------
```

---

## 5. ISR SAFETY POLICY

### 5.1 Absolute Rules

**NEVER call ANY LOG macro from:**
- ISR functions (`ISR(...)`, interrupt handlers)
- Functions called FROM ISR (ISR-reachable)
- `attachInterrupt()` callbacks

**Rationale:**
- `Serial.print()` blocks for 1-10ms
- ISR budget: <1μs (PHI2 timing constraint)
- Blocking in ISR causes crashes, data loss

### 5.2 ISR Diagnostic Pattern

**Problem:** Need to log ISR events for debugging

**Solution:** Volatile flag/counter pattern

**Implementation:**

```cpp
// 1. Declare volatile diagnostics (global or in class)
volatile uint8_t g_isr_event_count = 0;
volatile uint8_t g_isr_error_flags = 0;

// 2. In ISR: ONLY increment/set (atomic on AVR)
void SomeISR() {
  g_isr_event_count++;        // Safe: 8-bit write is atomic

  if (error_condition) {
    g_isr_error_flags |= 0x01; // Safe: single-byte operation
  }

  // NO LOG MACROS!
}

// 3. In main loop: Translate to logs
void loop() {
  static uint8_t last_count = 0;
  static uint8_t last_flags = 0;

  // Check for new events
  if (g_isr_event_count != last_count) {
    LOGD(PROTO, "ISR events: ");
    LOG_PRINTLN(g_isr_event_count);
    last_count = g_isr_event_count;
  }

  // Check for errors
  if (g_isr_error_flags != last_flags) {
    LOGW(PROTO, "ISR errors: 0x");
    LOG_HEX(g_isr_error_flags);
    LOG_NEWLINE();
    last_flags = g_isr_error_flags;
  }
}
```

**Benefits:**
- ISR stays fast (single-byte writes)
- Diagnostics preserved
- Logs happen safely in main loop

---

## 6. COMPILE-TIME GATING

### 6.1 Build Flags

**Debug Build (logging enabled):**
```
-DEASYSD_DEBUG_SERIAL
```

**Release Build (logging disabled):**
```
(no flags - default)
```

### 6.2 Macro Expansion

**Debug build:**
```cpp
LOGI(SD, "Card OK");

// Expands to:
Serial.print(F("[INFO][SD] "));
Serial.println(F("Card OK"));
```

**Release build:**
```cpp
LOGI(SD, "Card OK");

// Expands to:
((void)0)  // Compiles to nothing
```

**Result:** Zero code size, zero runtime overhead in release.

---

## 7. IMPLEMENTATION STRUCTURE

### 7.1 Files

```
Arduino/IRQHack64/
├── EasySDLog.h              // New logging system (replaces DebugLog.h)
└── LOGGING_SYSTEM_DESIGN.md // This document
```

### 7.2 Header Organization

```cpp
#ifndef _EASYSDLOG_H
#define _EASYSDLOG_H

// Section 1: Build configuration check
#ifdef EASYSD_DEBUG_SERIAL
  // Debug mode
#else
  // Release mode (stubs)
#endif

// Section 2: Initialization macros
// Section 3: Categorized logging macros
// Section 4: Variable output macros
// Section 5: Utility macros

#endif
```

---

## 8. MIGRATION STRATEGY

### 8.1 Phase 3A: Create EasySDLog.h
- Implement macro system
- Test compilation (debug + release)

### 8.2 Phase 3B: Fix ISR Violation
- Remove `DBG_PRINTLN_F` from `CartInterface::EnableCartridge()`
- Add volatile counter if diagnostic needed
- Add main loop handler

### 8.3 Phase 3C: Migrate All Code
- Replace ALL `DBG_*` with `LOG*` macros
- Add proper categories
- Remove old `DebugLog.h`

---

## 9. EXAMPLES

### 9.1 Typical Usage Pattern

```cpp
void setup() {
  LOG_BEGIN(57600);
  LOG_HEADER("IRQHack64 v2.1.0");

  LOGI(SYS, "Initializing...");

  if (initSD()) {
    LOGI(SD, "Card OK");
    LOG_PRINT_F("Free RAM: ");
    LOG_PRINTLN(FreeStack());
  } else {
    LOGE(SD, "Init failed - check card");
  }
}

void HandleOpenFile() {
  LOGD(FILE, "HandleOpenFile");

  char filename[13];
  GetFileName(filename);

  LOGI(FILE, "Opening: ");
  LOG_PRINTLN(filename);

  if (file.open(filename, O_READ)) {
    LOGI(FILE, "Success");
    LOGD(FILE, "Size: ");
    LOG_PRINTLN(file.size());
  } else {
    LOGE(FILE, "Open failed");
  }
}
```

### 9.2 ISR-Safe Diagnostics

```cpp
// Global diagnostics
volatile uint8_t g_isr_rx_count = 0;
volatile uint8_t g_isr_overflow = 0;

// ISR
void CartInterface::ReceiveInterrupt() {
  g_isr_rx_count++;

  if (readQueue.IsFull()) {
    g_isr_overflow++;
    return;
  }

  // ... receive logic ...
}

// Main loop
void loop() {
  static uint8_t last_rx = 0;
  static uint8_t last_ovf = 0;

  if (g_isr_rx_count != last_rx) {
    LOGT(PROTO, "RX bytes: ");
    LOG_PRINTLN(g_isr_rx_count);
    last_rx = g_isr_rx_count;
  }

  if (g_isr_overflow != last_ovf) {
    LOGW(PROTO, "Queue overflow count: ");
    LOG_PRINTLN(g_isr_overflow);
    last_ovf = g_isr_overflow;
  }

  // ... handle commands ...
}
```

---

## 10. VERIFICATION

Post-implementation verification:

1. **Compile test (debug):**
   ```
   -DEASYSD_DEBUG_SERIAL
   → Should compile, produce logs
   ```

2. **Compile test (release):**
   ```
   (no flags)
   → Should compile, no Serial usage
   ```

3. **ISR audit:**
   ```
   grep -r "LOG[EWIDТ]" ISR_functions/
   → Should return ZERO matches
   ```

4. **Size comparison:**
   ```
   Debug build:   ~25KB (with logging)
   Release build: ~18KB (no logging)
   ```

---

## 11. DESIGN RATIONALE

### Why no runtime filtering?
- Adds 2+ bytes global state
- Adds conditional checks (code size)
- AVR has 2KB RAM - every byte matters
- Compile-time filtering is free

### Why no buffering?
- Buffering requires RAM (128-256 bytes minimum)
- Adds complexity (buffer overflow, flush logic)
- Serial.print() is already buffered (64 bytes)

### Why categorical instead of module-based?
- Categories group by *function* (SD, DIR, FILE)
- Modules are *implementation* (CartApi, DirFunction)
- Function-based grouping better for debugging

### Why F() macro everywhere?
- AVR has 32KB flash, 2KB RAM
- String literals must stay in PROGMEM
- F() macro prevents RAM exhaustion

---

## 12. FUTURE ENHANCEMENTS (OPTIONAL)

Not in current scope, but possible:

1. **Timestamp support** (millis() prefix)
2. **Binary logging** (encode to save bandwidth)
3. **Multi-level builds** (INFO-only, DEBUG-only)
4. **Assertion macros** (LOG_ASSERT)
5. **Performance counters** (LOG_TIMING)

---

## END OF DESIGN SPECIFICATION

**Next:** Phase 3 Implementation
