# EasySD IRQHack64 Code Documentation Guide

**Version:** 1.0
**Date:** 2025-12-27
**Sprint:** Documentation & Safety Hardening

---

## Table of Contents

1. [Introduction](#introduction)
2. [Contract Block Format](#contract-block-format)
3. [File Prologue Template](#file-prologue-template)
4. [Logging Policy](#logging-policy)
5. [Safety Documentation Markers](#safety-documentation-markers)
6. [Sprint Marker Convention](#sprint-marker-convention)
7. [Examples](#examples)

---

## Introduction

This guide establishes consistent documentation patterns for the EasySD IRQHack64 firmware. All code should follow these standards to ensure:

- **Clarity:** Developers understand intent, constraints, and guarantees
- **Safety:** Buffer limits, ISR constraints, and state invariants are explicit
- **Maintainability:** Future changes can validate against documented contracts
- **Professionalism:** Code is production-ready and audit-friendly

**Key Principles:**
- Document **why**, not **what** (code shows what)
- Document **contracts** (preconditions, postconditions, error codes)
- Document **safety constraints** (buffer bounds, ISR timing, state invariants)
- Use **structured comments** (Doxygen-style tags)

---

## Contract Block Format

Every **public function** and **critical private function** must have a contract block:

### Template

```cpp
/**
 * @brief One-line purpose statement
 *
 * [Optional multi-line detailed description]
 *
 * @precondition Requirement 1 (e.g., "path must be NUL-terminated, < 64 bytes")
 * @precondition Requirement 2 (e.g., "SD card must be initialized")
 *
 * @postcondition Guarantee 1 (e.g., "currentPath updated, depth incremented")
 * @postcondition Guarantee 2 (e.g., "on failure, state unchanged (rollback)")
 *
 * @param name Parameter description
 * @param name2 Second parameter description
 * @return Return value meaning (e.g., "true if successful, false if path too deep")
 *
 * @error_codes ERROR_FILE_NOT_FOUND (0x01) - File does not exist
 * @error_codes ERROR_INVALID_STATE (0x02) - File already open
 *
 * @note Additional context (e.g., "Automatically calls ReInit() + Prepare()")
 * @note Performance consideration (e.g., "Blocking operation, ~10ms on SD")
 */
```

### Tag Descriptions

| Tag | Required | Purpose |
|-----|----------|---------|
| `@brief` | **Yes** | One-line summary (appears in IDE hover) |
| `@precondition` | **Critical functions** | What must be true before calling |
| `@postcondition` | **Critical functions** | What is guaranteed after calling |
| `@param` | If parameters | Describe each parameter |
| `@return` | If non-void | What the return value means |
| `@error_codes` | If protocol/API | List all error codes returned |
| `@note` | Optional | Additional context, caveats, performance notes |

### When to Use Contract Blocks

**Always document:**
- Public API functions (CartApi.h, DirFunction.h)
- State-changing functions (ChangeDirectory, HandleOpenFile)
- ISR functions (ReceiveInterrupt)
- Functions with complex logic (>20 lines)

**Can skip:**
- Trivial getters/setters
- Private helper functions with obvious purpose
- Inline functions <5 lines

---

## File Prologue Template

Every `.h` and `.cpp` file must start with a prologue explaining purpose and design:

### Template

```cpp
/**
 * @file filename.cpp
 * @brief Module purpose (1-3 sentences)
 *
 * [Optional multi-paragraph detailed description]
 *
 * Responsibilities:
 * - Key responsibility 1
 * - Key responsibility 2
 * - Key responsibility 3
 *
 * Key Invariants:
 * - Invariant description 1 (e.g., "CWD is single source of truth")
 * - Invariant description 2 (e.g., "Only one file open at a time")
 *
 * Safety Notes:
 * - Buffer limits (e.g., "currentPath[64]: max 63 bytes + NUL")
 * - ISR constraints (e.g., "ISR must complete <1μs")
 * - State machine requirements (e.g., "Must OPEN before READ")
 *
 * [Optional additional sections: Protocol, Dependencies, etc.]
 */
```

### Sections Explained

#### 1. `@file` and `@brief`
- `@file`: Exact filename (for Doxygen)
- `@brief`: 1-3 sentence module summary

#### 2. Responsibilities
List the **core jobs** this module performs. Keep it high-level:
- Good: "Maintain current working directory (CWD) state"
- Bad: "Calls SD.open() and iterates files"

#### 3. Key Invariants
Document **rules that must always be true**:
- State machine invariants (e.g., "File I/O state: IDLE | OPENED")
- Uniqueness constraints (e.g., "Only one file open at a time")
- Synchronization rules (e.g., "Every ChangeDirectory() calls ReInit()")

#### 4. Safety Notes
Explicitly document **constraints that prevent bugs**:
- **Buffer limits:** Sizes and validation logic
- **ISR constraints:** Timing budgets, forbidden operations (Serial.print, malloc)
- **State machine requirements:** Valid state transitions

### Example: CartApi.h

```cpp
/**
 * @file CartApi.h
 * @brief C64 cartridge API - command protocol and file I/O interface
 *
 * Responsibilities:
 * - Command dispatch table (HandleOpenFile, HandleReadFile, etc.)
 * - File I/O state management (workingFile handle)
 * - C64 ↔ Arduino protocol implementation
 * - Directory navigation integration (via DirFunction)
 *
 * Protocol:
 * - Command format: [CMD_BYTE] [PARAMS...] → [RESULT_BYTE] [DATA...]
 * - Commands: OPEN_FILE(0x10), READ_FILE(0x11), CLOSE_FILE(0x12), GET_DIR_ENTRY(0x20)
 * - Error codes: SUCCESS(0x00), ERROR_FILE_NOT_FOUND(0x01), ERROR_INVALID_STATE(0x02)
 *
 * Key Invariants:
 * - workingFile states: IDLE (no file open) | OPENED (file ready for read)
 * - File operations: Must OPEN before READ, must CLOSE when done
 * - State machine: READ operations only valid when file OPENED
 *
 * Safety Notes:
 * - Buffer limits: fileBuffer[16], dirname[64], path buffers validated
 * - State validation: No READ allowed if workingFile not OPENED
 * - ISR interaction: HandleStream() disables interrupts during buffer swap
 */
```

---

## Logging Policy

**Release builds:** UART-free (0 Serial calls) - TX/RX pins available for other use
**Debug builds:** Structured logs via `DebugLog.h` macros

### DebugLog.h Macros

| Macro | Use Case | Example |
|-------|----------|---------|
| `DBG_INFO(msg)` | General information | `DBG_INFO(F("[DIR] Changed to: "));` |
| `DBG_WARN(msg)` | Warnings (non-fatal) | `DBG_WARN(F("[SD] Card slow, retry..."));` |
| `DBG_ERR(msg)` | Errors (recoverable) | `DBG_ERR(F("[API] File not found"));` |
| `DBG_TRACE(msg)` | Verbose tracing | `DBG_TRACE(F("[ISR] Byte received"));` |

### Log Prefix Convention

All logs must use prefixes to identify subsystem:

| Prefix | Subsystem | Example |
|--------|-----------|---------|
| `[DIR]` | Directory navigation | `DBG_INFO(F("[DIR] Depth: 2"));` |
| `[API]` | Cartridge API | `DBG_INFO(F("[API] CMD: 0x10"));` |
| `[SD]` | SD card operations | `DBG_ERR(F("[SD] Init failed"));` |
| `[ERR]` | Generic errors | `DBG_ERR(F("[ERR] Invalid state"));` |
| `[SYS]` | System/startup | `DBG_INFO(F("[SYS] Boot OK"));` |

### String Storage: F() Macro

**ALWAYS** use `F()` macro for string literals to save RAM:

```cpp
// GOOD: String stored in PROGMEM (flash)
DBG_INFO(F("[DIR] Changed to: "));

// BAD: String consumes precious RAM
DBG_INFO("[DIR] Changed to: ");  // DON'T DO THIS
```

### Migration from Serial.print

**Before (old pattern):**
```cpp
#ifdef EASYSD_DEBUG_SERIAL
  Serial.print(F("[DIR] Changed to: "));
  Serial.println(directory);
#endif
```

**After (new pattern):**
```cpp
DBG_INFO(F("[DIR] Changed to: "));
DBG_INFO(directory);  // DebugLog.h handles newlines automatically
```

### ISR Logging (FORBIDDEN)

**NEVER** use Serial.print or DebugLog macros inside ISR code:

```cpp
// WRONG - ISR code MUST NOT log
static void ReceiveInterrupt() {
    DBG_TRACE(F("Byte received"));  // FORBIDDEN - blocks, causes crashes
    // ... ISR logic ...
}

// CORRECT - Log outside ISR if needed
void ProcessReceivedByte() {
    DBG_TRACE(F("[ISR] Processing byte"));  // Safe - not in ISR
    // ... processing logic ...
}
```

---

## Safety Documentation Markers

Use `// SAFETY:` comments to document constraints that prevent bugs:

### Buffer Bounds

```cpp
// SAFETY: Buffer bounds - path limited to 63 bytes + NUL
//   currentPath[64] validation at line 166-167:
//     - Depth limit: 5 levels
//     - Length check: ensures <64 bytes total
//   Protection: ChangeDirectory() fails if limits exceeded
char currentPath[64];
```

### ISR Safety

```cpp
// SAFETY: ISR timing constraints
//   - Max execution time: <1 microsecond (PHI2 = 1MHz)
//   - NO Serial.print (blocks)
//   - NO heap allocation (malloc)
//   - Volatile access: atomic by nature (8-bit AVR)
//   - ByteQueue.write(): lock-free ringbuffer
static void ReceiveInterrupt() {
    // ... ISR code ...
}
```

### State Invariants

```cpp
// SAFETY: File I/O state machine
//   Precondition: workingFile must be OPENED
//   Postcondition: Returns error if file IDLE
//   Invariant: Only one file open at a time
void HandleReadFile() {
    if (!workingFile.isOpen()) {
        // Return ERROR_INVALID_STATE to C64
    }
    // ... read logic ...
}
```

### When to Add SAFETY Comments

**Always document:**
- Buffer operations (strcpy, strcat, sprintf)
- ISR functions and volatile variables
- State machine transitions
- Critical sections (noInterrupts/interrupts)
- Timing-sensitive code

**Can skip:**
- Standard library calls with no special constraints
- Simple arithmetic
- Obvious conditionals

---

## Sprint Marker Convention

When adding features or fixes, add sprint markers to track evolution:

### Pattern

```cpp
// Sprint N: Feature/fix description
```

### Examples

```cpp
// Sprint 5: Added resync pattern (chdir → reopen → count)
bool ReInit() {
    // ...
}

// Sprint 6: Cold boot retry logic (3 attempts, 200ms delay)
void setup() {
    // ...
}

// Sprint 7: Artifact separation (build/artifacts/ → Arduino/IRQHack64/)
void generateBuildConfig() {
    // ...
}
```

**Purpose:** Provides historical context for design decisions

---

## Examples

### Example 1: DirFunction.h - ChangeDirectory

```cpp
/**
 * @brief Navigate to subdirectory and resync SD handle
 *
 * Implements the Sprint 5 resync pattern: directory change followed by
 * ReInit() + Prepare() to ensure SD card handle stays synchronized.
 *
 * @precondition directory != nullptr
 * @precondition directory name valid (no '/', '..', etc.)
 * @precondition strlen(directory) < 64
 * @precondition Current depth < 5 (MAX_DEPTH)
 *
 * @postcondition On success: currentPath updated, depth++, ReInit() + Prepare() called
 * @postcondition On failure: currentPath unchanged (rollback), returns false
 *
 * @param directory Subdirectory name (relative, not absolute path)
 * @return true if successful, false if path too deep or chdir failed
 *
 * @note Automatically calls ReInit() + Prepare() (Sprint 5 pattern)
 * @note Uses savedPath for rollback on error
 */
bool ChangeDirectory(const char *directory);
```

### Example 2: CartApi.cpp - HandleOpenFile

```cpp
/**
 * @brief Open file for reading (C64 protocol command 0x10)
 *
 * @precondition workingFile in IDLE state (no file currently open)
 * @precondition filename valid (exists in current directory)
 *
 * @postcondition On success: workingFile OPENED, returns SUCCESS(0x00) to C64
 * @postcondition On failure: workingFile IDLE, returns ERROR_FILE_NOT_FOUND(0x01)
 *
 * @protocol Command: [0x10] [filename_length] [filename_bytes...]
 * @protocol Response: [result_code] [file_size_4_bytes] (if success)
 *
 * @error ERROR_FILE_NOT_FOUND (0x01) - File does not exist
 * @error ERROR_INVALID_STATE (0x02) - File already open
 *
 * @note Must call HandleCloseFile before opening another file
 */
void HandleOpenFile() {
    // Implementation...
}
```

### Example 3: CartInterface.cpp - ISR Safety

```cpp
// SAFETY: ISR timing constraints
//   - Max execution time: <1 microsecond (PHI2 = 1MHz)
//   - NO Serial.print (blocks, causes crashes)
//   - NO heap allocation (malloc)
//   - Volatile access: atomic by nature (8-bit AVR)
//   - ByteQueue.write(): lock-free ringbuffer
static void ReceiveInterrupt() {
    // Read pin state
    int pinState = digitalRead(DATA_PIN);

    // Update receive state machine
    if (receiveState == IDLE) {
        // Start reception...
    }

    // Write to queue (lock-free operation)
    readQueue.write(currentByte);
}
```

### Example 4: DirFunction.cpp - Buffer Safety

```cpp
// SAFETY: Path buffer bounds
//   currentPath[64] = max 63 chars + NUL
//   Validation at line 166-167:
//     - Depth limit: 5 levels
//     - Length check: ensures <64 bytes total
//   Protection: ChangeDirectory() fails if limits exceeded
bool DirFunction::ChangeDirectory(const char *directory) {
    // Check depth
    if (depth >= MAX_DEPTH) {
        DBG_ERR(F("[DIR] Max depth reached"));
        return false;
    }

    // Check length
    if (strlen(currentPath) + strlen(directory) + 2 > 63) {
        DBG_ERR(F("[DIR] Path too long"));
        return false;
    }

    // Safe to proceed
    strcat(currentPath, "/");
    strcat(currentPath, directory);
    depth++;

    return true;
}
```

---

## Summary Checklist

When writing new code or refactoring, ensure:

- [ ] **File prologue** present (purpose, responsibilities, invariants, safety)
- [ ] **Function contracts** on public/critical functions (pre/post conditions, errors)
- [ ] **Logging** uses DebugLog.h macros (no direct Serial.print in debug code)
- [ ] **F() macro** used for all string literals
- [ ] **SAFETY comments** on buffers, ISR code, state machines
- [ ] **Sprint markers** for new features (context for future maintainers)

**Target:** Professional, audit-ready code that is safe, maintainable, and self-documenting.

---

**End of COMMENTING_GUIDE.md**
