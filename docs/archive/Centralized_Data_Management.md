# Centralized Data Management for EasySD Gemini Project

This document summarizes the current centralized data and symbol-management rules for the EasySD codebase. Its purpose is to keep builds stable, prevent Zero Page collisions, and document a maintainable `64tass` include chain. If this document ever disagrees with the source, the source is authoritative.

---

## 1. Architectural Principles

The project follows a **Linear Include Chain** model. Because `64tass` does not support conventional C-style include guards such as `.ifndef`, repeated inclusion leads to duplicate-definition errors.

### 1.1. Current Include Chain
In the current source tree, symbols flow through the chain below:
`CartLibStream.s` (wrapper)
    └── `CartZpMap.inc` (ZP definitions)
  └── `CartLibHi.s` (high-level API)
      └── `CartLib.s` (low-level interface)
                    └── `CartLibCommon.s` (core system addresses)
                            └── `Common/System.inc` (C64 hardware and KERNAL symbols)
                            └── `Common/EasySD.inc` (EasySD commands and status codes)

The API macros are a separate layer. `APIMacros.s` is not pulled in automatically by this chain, so any file that uses those macros must include it explicitly.

### 1.2. Include Ownership
This is currently a project convention rather than a rule enforced by a dedicated build validator:
*   **`CartZpMap.inc`** should enter through the normal include chain, not be included directly from multiple locations.
*   **`CartLibCommon.s`** belongs to `CartLib.s` and should not be included directly from plugins or menu code.
*   **Plugins/Menu** should include the wrapper level (`CartLibStream.s`, plus `APIMacros.s` when needed), not the internal layers of the chain.

---

## 2. Central Definition Files

### 2.1. `System.inc` (C64 Standard)
This file contains fixed Commodore 64 addresses. Prefer canonical names over local aliases:
*   **KERNAL entry points (ROM):** `K_OPEN` ($F34A), `K_CLOSE` ($F291), `K_CHKIN` ($F20E), `K_CHRIN` ($F157), `K_CLRCHN` ($F32F).
*   **KERNAL RAM vectors:** `V_OPEN` ($031A), `V_CLOSE` ($031C), `V_CHKIN` ($031E), `V_CLRCHN` ($0322), `V_CHRIN` ($0324).
*   **Hardware registers:** `VIC_CONTROL_1` ($D011), `VIC_INT_ACK` ($D019), `CIA_1_BASE` ($DC00), and others.
*   **Hardware masks:** `VIC_DEN` ($10), `VIC_INT_RASTER` ($01).

### 2.2. `EasySD.inc` (Hardware API)
This file contains EasySD-specific commands and status codes:
*   **Commands:** `COMMAND_READ_FILE` (78), `COMMAND_OPEN_FILE` (2), `COMMAND_STREAM` (25), and others.
*   **Status codes:** `CARTRIDGE_READY` ($00), `CARTRIDGE_PROCESS_OK` ($80).
*   **KERNAL parameters:** `KERNAL_FILENAME_LENGTH` ($B7), `KERNAL_FILENAME_LOW` ($BB), `KERNAL_STATUS` ($90).

### 2.3. `CartZpMap.inc` (Zero Page Map)
This file is the **single source of truth** for every routine that uses Zero Page. Every symbol defined here uses the `ZP_` prefix.

| Range | Description | Example labels |
|:---|:---|:---|
| **$64** | Foreground Sync | `ZP_IRQ_WaitHandle` |
| **$69-$6A** | Data/Seek Pointer | `ZP_IRQ_SEEK_LOW`, `ZP_IRQ_SEEK_HIGH` |
| **$6B** | Data Length | `ZP_IRQ_DATA_LENGTH` |
| **$6C-$6D** | Buffer Pointer | `ZP_IRQ_DATA_LOW`, `ZP_IRQ_DATA_HIGH` |
| **$73-$74** | Callback Pointer | `ZP_IRQ_CALLBACK_LO`, `ZP_IRQ_CALLBACK_HI` |
| **$75-$76** | Seek Upper Word | `ZP_IRQ_SEEK_UPPER_LO`, `ZP_IRQ_SEEK_UPPER_HI` |
| **$77** | Temp Storage | `ZP_IRQ_TEMP` |
| **$80-$87** | `LoadFileBySize` | `ZP_LF_SIZE0..3`, `ZP_LF_SKIP_LO/HI`, `ZP_LF_PAYLOAD_LO/HI` |
| **$8B-$8E** | *(reserved, currently unused)* | — |
| **$90-$95** | `StreamLargeFile` | `ZP_STREAM_TARGET_ADDR_LO/HI`, `ZP_STREAM_BYTES_REMAIN_0..3` |

---

## 3. Developer Usage Rules

### 3.1. Inclusion from Plugins and Menu Code
Do not include internal `.inc` files directly at the top of a plugin if the code already depends on the loader chain.
**Correct pattern:**
```assembly
; Plugin code...
.include "../../Loader/CartLibStream.s" ; Pulls in the shared ZP and system definitions through the chain
```

### 3.2. Referencing Zero Page
Never use hardcoded addresses or prefix-less symbol names.
*   **Wrong:** `STA $6C` or `STA IRQ_DATA_LOW`
*   **Correct:** `STA ZP_IRQ_DATA_LOW`

### 3.3. Using Canonical Names
Avoid local aliases when a shared canonical name already exists. This improves readability and keeps central changes manageable.
*   **Wrong:** `STA FILENAME_LOW`
*   **Correct:** `STA KERNAL_FILENAME_LOW`

---

## 4. DEBUG Mode Behavior and Limits

The project supports the `DEBUG=1` build flag (`64tass: -D DEBUG=1`), which **materially changes** runtime behavior. DEBUG mode is suitable **only** for development and debugging in VICE.

### 4.1. DEBUG Mode Changes

**CartLibHi.s - `PROT_WaitProcessing` bypass:**
```assembly
PROT_WaitProcessing
.if DEBUG = 1
    CLC
    RTS
.else
    ; normal hardware polling
```

**Effect:**
- Processing waits appear to succeed immediately in debug builds.
- This makes VICE iteration faster, but it does not represent real Arduino communication.
- Older SafeStream-specific debug descriptions should no longer be treated as current normative behavior.

### 4.2. Critical Warning

**⚠️ A `DEBUG=1` build must never be run on real EasySD hardware.**

**Why:**
- Because of the `PROT_WaitProcessing` bypass, the C64 does **not wait** for the Arduino response.
- Memory may remain uninitialized or contain invalid data.
- The program may appear to run while behaving incorrectly.
- This creates silent failures that are hard to diagnose.

**Usage:**
```bash
# In VICE (development):
64tass -D DEBUG=1 EasySDMenu.s -o menu.prg

# On real hardware (production):
64tass -D DEBUG=0 EasySDMenu.s -o menu.prg
# Or simply:
64tass EasySDMenu.s -o menu.prg  (DEBUG alapértelmezetten 0)
```

### 4.3. Recommended Development Workflow

1. **Test in VICE** (`DEBUG=1`):
    - Fast iteration
    - Parameter validation is active
    - No Arduino hardware required

2. **Production build** (`DEBUG=0`):
    - Real hardware communication
    - Cartridge ROML chip programming
    - Final testing on physical C64 hardware

---

## 5. Configuration Rules Summary

*   The **$80-$87** range is reserved exclusively for `LoadFileBySize`.
*   Menu and plugin-local temporary variables may use the **$FB-$FE** user range, but those should not be added to `CartZpMap.inc`.
*   If a new routine needs ZP storage, it must be registered in `CartZpMap.inc` to avoid collisions.
