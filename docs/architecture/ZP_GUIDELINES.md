# Zero Page Guidelines - EasySD / IRQHack64

**Document Type:** Normative (Architectural Constitution)
**Version:** 1.0
**Created:** 2025-12-27 (Sprint 8)
**Status:** CANONICAL - All Zero Page usage must conform to this document

---

## 1. Purpose and Scope

This document defines the **architectural rules and conventions** for Zero Page (ZP) memory usage in the EasySD / IRQHack64 project. Zero Page is a **scarce, critical resource** on the 6502 architecture that requires disciplined management to prevent conflicts, ensure deterministic behavior, and maintain system stability.

**This document is normative**: All code that uses Zero Page memory MUST conform to these guidelines. Deviations require architectural review and explicit documentation.

---

## 2. Zero Page as a Resource

### 2.1 Fundamental Constraints

Zero Page memory ($00-$FF, 256 bytes) is the **most valuable memory** on the 6502:

- **Performance**: ZP addressing modes are faster (2 cycles vs 4 cycles) and use less code space (2 bytes vs 3 bytes)
- **Scarcity**: Only 256 bytes available, shared among:
  - C64 Kernal/BASIC ($00-$8F typically reserved)
  - IRQ/NMI handlers (need stable, dedicated locations)
  - Application code (menu system, plugins)
  - Protocol state (C64 ↔ Arduino communication)
- **Criticality**: Misuse causes hard-to-debug conflicts, race conditions, and system crashes

### 2.2 Zero Page as Scarce Resource

**Key Principle**: Treat Zero Page like a critical section in multithreaded programming.

- **Ownership** must be explicit and documented
- **Lifetime** must be clearly defined
- **Overlays** (temporal reuse) require careful coordination
- **IRQ safety** is mandatory for addresses used by interrupt handlers

---

## 3. Layered Data Model

Zero Page usage follows a **three-layer model**:

### Layer 1: System Reserved ($00-$8F)
- **Owner**: C64 Kernal, BASIC, Operating System
- **Lifetime**: Entire C64 session
- **Access**: Read-only (observing system state) or completely avoided
- **Examples**: $01 (I/O port control), $14-$15 (Kernal vectors)
- **Rule**: **DO NOT WRITE** to system-reserved ZP addresses

### Layer 2: Protocol Layer ($64-$77 in current implementation)
- **Owner**: IRQHack64 communication protocol
- **Lifetime**: While IRQ/NMI handlers are active
- **Access**: Restricted to CartLibCommon.s and IRQ-safe code
- **Characteristics**:
  - Used by IRQ/NMI interrupt handlers
  - Must remain stable across plugin/menu boundaries
  - Requires atomic access patterns (no partial updates visible to IRQ)
- **Rule**: **IRQ handlers have priority** over mainline code

### Layer 3: Application Layer ($80+)
- **Owner**: Loader, Menu, Plugins, API functions
- **Lifetime**: Varies by category (see Section 4)
- **Access**: General application code
- **Characteristics**:
  - Can be overlaid (temporal reuse) with proper coordination
  - Must not interfere with Protocol Layer
  - Must document IRQ safety status

---

## 4. Zero Page Categories (Semantic Classification)

All Zero Page variables fall into **four semantic categories**:

### 4.1 API (Function Parameters / Return Values)

**Purpose**: Passing parameters to and from library functions

**Characteristics**:
- **Lifetime**: Short (duration of function call only)
- **Ownership**: Caller sets up, function consumes, caller reclaims
- **IRQ Safety**: Generally IRQ-unsafe (mainline only)
- **Overlay Potential**: HIGH (can be reused after function returns)

**Example Use Cases**:
- File size passed to `LoadFileBySize` (ZP_LF_SIZE0..3)
- Target address for data loading (ZP_LF_PAYLOAD_LO/HI)
- Streaming parameters (ZP_STREAM_TARGET_ADDR_LO/HI)

**Rules**:
- Values are **invalid after function returns**
- **Never assume API ZP persists** across function calls
- Document which function owns which API ZP addresses

---

### 4.2 STATE (Persistent Application State)

**Purpose**: Long-lived data that persists across multiple operations

**Characteristics**:
- **Lifetime**: Long (multiple function calls, entire plugin session)
- **Ownership**: Clear owner (menu system, specific plugin, protocol layer)
- **IRQ Safety**: Depends on usage (document explicitly)
- **Overlay Potential**: LOW (must remain valid across operations)

**Example Use Cases**:
- Current protocol state (IRQ wait handles, status flags)
- Menu system state (selected item, directory position)
- Plugin persistent data (playback position, configuration)

**Rules**:
- **Must be preserved** across function calls unless explicitly documented otherwise
- **Overlays forbidden** unless owner explicitly releases ownership
- **Document lifetime** clearly in CartZpMap.inc

**Anti-Pattern**:
```assembly
; ❌ WRONG: Using STATE ZP as temporary without preserving
LDA ZP_SOME_STATE_VAR
PHA                     ; Forgot to save!
; ... operations that modify ZP_SOME_STATE_VAR ...
; Original value lost - system breaks
```

---

### 4.3 TMP (Temporary Scratch Space)

**Purpose**: Short-lived temporary storage within a single code block

**Characteristics**:
- **Lifetime**: Very short (single function or code block)
- **Ownership**: Current executing code
- **IRQ Safety**: IRQ-unsafe (unless explicitly marked IRQ_TMP)
- **Overlay Potential**: VERY HIGH (reuse aggressively)

**Example Use Cases**:
- Loop counters
- Intermediate calculations
- Address computation temporaries

**Rules**:
- Values are **undefined on entry** to any function
- **No expectation of preservation** across function calls
- Can be freely overlaid with other TMP variables
- **Must not be used in IRQ handlers** unless marked IRQ_TMP

**Best Practice**:
```assembly
; ✅ CORRECT: TMP used locally, no assumptions
MyFunction:
    LDA #$00
    STA ZP_TMP_COUNTER      ; Initialize locally (don't assume 0)
@Loop:
    ; ... use ZP_TMP_COUNTER ...
    INC ZP_TMP_COUNTER
    BNE @Loop
    RTS                     ; Value discarded after return
```

---

### 4.4 WORK (Working Memory for Complex Operations)

**Purpose**: Medium-lived storage for multi-step operations

**Characteristics**:
- **Lifetime**: Medium (multiple related function calls within an operation)
- **Ownership**: Operation owner (e.g., streaming subsystem, file loading)
- **IRQ Safety**: Generally IRQ-unsafe (mainline only)
- **Overlay Potential**: MEDIUM (reuse after operation completes)

**Example Use Cases**:
- Multi-byte file size during loading sequence
- Streaming state during large file transfer
- Directory traversal working variables

**Difference from TMP**:
- **TMP**: Single function scope
- **WORK**: Multi-function operation scope (e.g., setup → execute → cleanup)

**Rules**:
- **Valid only during specific operations** (document which operations)
- **Can be overlaid** with other WORK variables if operations don't overlap
- **Must document operation boundaries** clearly

**Example**:
```assembly
; ✅ CORRECT: WORK used for multi-step operation
PrepareFileLoad:
    ; Setup phase
    JSR IRQ_GetInfoForFile
    LDA FileSize0
    STA ZP_WORK_FILE_SIZE_0  ; WORK valid from here...
    RTS

ExecuteFileLoad:
    ; Execute phase
    LDA ZP_WORK_FILE_SIZE_0  ; ...still valid here...
    JSR LoadFileBySize
    RTS

CleanupFileLoad:
    ; Cleanup phase
    ; ZP_WORK_FILE_SIZE_0 no longer needed
    RTS                      ; ...WORK invalid after operation completes
```

---

## 5. Ownership and Lifetime

### 5.1 Ownership Model

Every Zero Page address has an **owner** at any given time:

**Owner Types**:
1. **System** (C64 Kernal/BASIC) - Permanent ownership
2. **Protocol** (IRQ/NMI handlers) - Permanent ownership (while active)
3. **Loader** (boot/menu system) - Ownership during menu operation
4. **Plugin** (specific plugin code) - Ownership during plugin execution
5. **Temporary** (current function) - Ownership during function execution

### 5.2 Ownership Transfer

Ownership can transfer between entities, but **must be explicit**:

**Safe Transfer Pattern**:
```assembly
; Plugin acquires ownership from menu system
PluginEntry:
    ; Implicit transfer: Menu releases ZP_WORK_xxx, Plugin acquires
    ; (documented in plugin entry point contract)
```

**Unsafe Transfer**:
```assembly
; ❌ WRONG: Implicit assumption without documentation
SomeFunction:
    LDA ZP_WORK_SOMETHING    ; Who owns this? Undefined!
```

### 5.3 Lifetime Documentation

**MANDATORY**: Every ZP variable must document its lifetime in CartZpMap.inc:

**Good Documentation Pattern**:
```assembly
; Lifetime: During LoadFileBySize call only
; Owner: LoadFileBySize function (CartLibHi.s)
; Category: API
ZP_LF_SIZE0 = $80
```

**Insufficient Documentation**:
```assembly
; ❌ WRONG: No lifetime, no owner
ZP_SOMETHING = $80
```

---

## 6. IRQ/NMI Separation (Critical)

### 6.1 The IRQ Safety Problem

IRQ/NMI handlers execute **asynchronously** and can interrupt mainline code at any time. This creates race conditions if both IRQ and mainline code access the same ZP address without coordination.

**Example Race Condition**:
```assembly
; Mainline code (interruptible)
LDA #$12
STA ZP_SHARED       ; ← IRQ occurs here!
LDA #$34
STA ZP_SHARED+1     ; Data corrupted if IRQ also writes ZP_SHARED

; IRQ Handler (interrupts above)
ISR:
    LDA #$FF
    STA ZP_SHARED   ; ← Overwrites mainline's $12!
    RTI
```

### 6.2 Separation Rules

**Rule 1: Dedicated IRQ ZP Addresses**
- IRQ handlers must use **dedicated ZP addresses** not shared with mainline code
- Prefix: `ZP_IRQ_*` (e.g., `ZP_IRQ_DATA_LOW`)
- Lifetime: Permanent (while IRQ handler is active)

**Rule 2: Mainline → IRQ Communication**
- Mainline can **write** to IRQ ZP addresses (setup phase)
- Mainline must **disable IRQ** during multi-byte writes:
  ```assembly
  SEI                    ; Disable IRQ
  LDA DataLo
  STA ZP_IRQ_DATA_LOW    ; Atomic 16-bit write
  LDA DataHi
  STA ZP_IRQ_DATA_HIGH
  CLI                    ; Re-enable IRQ
  ```

**Rule 3: IRQ → Mainline Communication**
- IRQ can **write** status flags (e.g., ZP_IRQ_STATUS)
- Mainline must **poll** (read-only) IRQ status:
  ```assembly
  @Wait:
      LDA ZP_IRQ_STATUS
      BEQ @Wait          ; Wait for IRQ to set flag
  ```

**Rule 4: No Shared TMP/WORK**
- **IRQ TMP** and **Mainline TMP** must be separate
- Exception: Documented, synchronized handshake protocols

### 6.3 IRQ-Safe vs IRQ-Unsafe

**IRQ-Safe ZP Addresses**:
- Used exclusively by IRQ handlers OR
- Read-only in mainline (polling) OR
- Written atomically with IRQ disabled (SEI/CLI)

**IRQ-Unsafe ZP Addresses**:
- Used only in mainline code
- **Never accessed** in IRQ handlers
- Can be freely modified without SEI/CLI

**Documentation Requirement**:
Every ZP variable must declare IRQ safety status:
```assembly
; IRQ Safety: IRQ-safe (IRQ handler exclusive)
ZP_IRQ_DATA_LOW = $6C

; IRQ Safety: IRQ-unsafe (mainline only)
ZP_LF_SIZE0 = $80
```

---

## 7. ZP → RAM Shadow Pattern (State Preservation)

### 7.1 The State Preservation Problem

**Problem**: Plugins/menus share ZP addresses but need to preserve state across context switches.

**Example**:
- Menu uses ZP_WORK_MENU_INDEX ($FB)
- Plugin overwrites $FB for its own purposes
- Returning to menu → ZP_WORK_MENU_INDEX corrupted → menu broken

### 7.2 Shadow RAM Solution

**Principle**: Long-lived STATE data should reside in **RAM**, with ZP used only as a **temporary working copy**.

**Pattern**:
```assembly
; RAM: Long-term storage (512-byte page in RAM)
MenuState_Index     .byte ?     ; Permanent storage in RAM

; ZP: Working copy (fast access during menu operation)
ZP_MENU_WORK_INDEX  = $FB

; Load state into ZP
MenuEntry:
    LDA MenuState_Index         ; Load from RAM
    STA ZP_MENU_WORK_INDEX      ; Copy to ZP for fast access
    ; ... menu operations use ZP_MENU_WORK_INDEX ...

; Save state back to RAM
MenuExit:
    LDA ZP_MENU_WORK_INDEX      ; Read from ZP
    STA MenuState_Index         ; Save to RAM
    ; ZP now free for plugin use
    RTS
```

### 7.3 When to Use Shadow RAM

**Use Shadow RAM when**:
- Data must persist across plugin/menu boundaries
- Data lifetime > single operation
- Data owner changes (menu → plugin → menu)

**Don't Need Shadow RAM when**:
- Data lifetime = single function call (use API category)
- Data lifetime = single operation (use TMP/WORK category)
- Owner never changes (permanent protocol state)

### 7.4 Shadow RAM Best Practices

1. **Explicit Load/Save**: Always load from RAM on entry, save on exit
2. **Single Source of Truth**: RAM is authoritative, ZP is cache
3. **Document Shadow Relationship**: Link ZP variable to RAM counterpart in comments
4. **Minimize ZP Footprint**: Only cache what's needed for performance

**Example Documentation**:
```assembly
; Category: WORK
; Lifetime: During menu operation
; Shadow: MenuState_Index (RAM)
; IRQ Safety: IRQ-unsafe
ZP_MENU_WORK_INDEX = $FB
```

---

## 8. Overlay Rules (Temporal Reuse)

### 8.1 Overlay Concept

**Overlay** = Reusing the same ZP address for different purposes at different times.

**Example**:
```assembly
; Time T1: Loading file
ZP_WORK_LOAD = $FB    ; Used by LoadFileBySize

; Time T2: Playing audio (after load completes)
ZP_WORK_AUDIO = $FB   ; Same address, different purpose
```

### 8.2 Safe Overlay Conditions

Overlay is **safe** only when:

1. **Lifetimes Don't Overlap**: Previous owner has finished before new owner starts
2. **Explicit Boundary**: Clear transition point (function return, plugin exit, etc.)
3. **Documented**: CartZpMap.inc shows both uses with lifetime notes
4. **No Hidden Dependencies**: No code assumes old value persists

### 8.3 Overlay Categories

**High Overlay Safety** (Recommended):
- TMP variables (single function scope)
- API variables (function call scope)
- Different plugins (mutually exclusive execution)

**Medium Overlay Safety** (Requires Care):
- WORK variables in different operations (ensure operations don't overlap)
- Menu ↔ Plugin boundary (with shadow RAM pattern)

**Low Overlay Safety** (Dangerous)**:
- STATE variables (risk of state loss)
- IRQ ↔ Mainline (race conditions)
- Implicit assumptions (undocumented lifetimes)

### 8.4 Overlay Documentation Pattern

**MANDATORY**: Overlaid ZP addresses must document both uses:

```assembly
; === $FB OVERLAY POOL ===
; Lifetime: During file loading operation
; Category: WORK
ZP_WORK_FILE_LOAD = $FB

; Lifetime: During audio playback (after load completes)
; Category: WORK
; Overlay: Safe (file load completes before audio starts)
ZP_WORK_AUDIO_BUFFER = $FB
```

### 8.5 Forbidden Overlays

**NEVER overlay**:
- Protocol layer ZP (IRQ handlers depend on stability)
- Across IRQ ↔ Mainline boundary without synchronization
- STATE variables without shadow RAM pattern
- Multi-byte values with single-byte values (alignment issues)

---

## 9. Naming Conventions

### 9.1 Standard Prefix

**ALL Zero Page symbols MUST use the `ZP_` prefix**.

**Rationale**:
- Clearly distinguishes ZP from RAM variables
- Prevents accidental conflicts with labels
- Makes ZP usage auditable (grep for `ZP_`)

### 9.2 Naming Pattern

**Format**: `ZP_<MODULE>_<CATEGORY>_<DESCRIPTION>`

**Components**:
- `MODULE`: Owner module (e.g., LF=LoadFileBySize, IRQ=Protocol, STREAM=Streaming)
- `CATEGORY`: Semantic category (API, STATE, TMP, WORK)
- `DESCRIPTION`: Descriptive name (SIZE, ADDR, COUNTER, etc.)

**Examples**:
```assembly
; Good naming (clear module, category, description)
ZP_LF_API_SIZE0           ; LoadFileBySize API parameter (size byte 0)
ZP_IRQ_STATE_STATUS       ; IRQ handler state variable
ZP_STREAM_WORK_BYTES_REMAIN  ; Streaming WORK variable

; Bad naming (no module, no category)
ZP_SIZE                   ; ❌ Which module? Which category?
ZP_TEMP                   ; ❌ Too generic
SOME_VAR = $80            ; ❌ Missing ZP_ prefix
```

### 9.3 IRQ Variable Naming

**IRQ-related variables** must include `IRQ` in the module name:

```assembly
ZP_IRQ_STATE_WAIT_HANDLE  ; IRQ state variable
ZP_IRQ_TMP_COUNTER        ; IRQ temporary (used in ISR)
ZP_IRQ_API_DATA_LOW       ; IRQ API parameter
```

---

## 10. CartZpMap.inc Structure

### 10.1 Single Source of Truth

**CartZpMap.inc** is the **ONLY file** that defines ZP addresses. All other files `.include` this file.

**Rules**:
- **Never hardcode ZP addresses** (e.g., `LDA $80` is forbidden)
- **Always use symbolic names** (e.g., `LDA ZP_LF_SIZE0`)
- **Never redefine** ZP symbols in other files

### 10.2 Required Documentation for Each ZP Variable

**MANDATORY fields**:
```assembly
; Category: API | STATE | TMP | WORK
; Lifetime: <specific lifetime description>
; Owner: <module or function name>
; IRQ Safety: IRQ-safe | IRQ-unsafe
; [Optional] Overlay: <overlay information>
; [Optional] Shadow: <RAM variable name>
ZP_EXAMPLE = $80
```

**Example**:
```assembly
; Category: API
; Lifetime: Duration of LoadFileBySize call only
; Owner: LoadFileBySize function (CartLibHi.s)
; IRQ Safety: IRQ-unsafe (mainline only)
; Overlay: Safe (can reuse after function returns)
ZP_LF_SIZE0 = $80
```

### 10.3 Logical Block Organization

CartZpMap.inc should be organized into **logical blocks**:

1. **Protocol Layer** (IRQ/NMI communication)
2. **API Parameters** (function call interfaces)
3. **State Variables** (persistent state)
4. **Work Variables** (operation-scoped)
5. **Temporary Variables** (function-scoped)

**Visual Separation**:
```assembly
; ============================================================
; PROTOCOL LAYER - IRQ/NMI Communication ($64-$77)
; ============================================================
; (IRQ variables here)

; ============================================================
; API PARAMETERS - Function Call Interface ($80-$87)
; ============================================================
; (API variables here)
```

---

## 11. Compliance and Enforcement

### 11.1 Mandatory Compliance

**All code** (existing and new) must comply with these guidelines:

- **Sprint 8**: ✅ Guidelines documented (this document)
- **Sprint 9**: ✅ Current ZP usage inventoried and audited
- **Sprint 10**: ✅ CartZpMap.inc restructured for compliance
- **Sprint 11**: ✅ ZP variable names aligned with conventions

### 11.2 Review Requirements

**Any new ZP variable** requires:
1. Documented category, lifetime, owner, IRQ safety
2. Added to CartZpMap.inc (not hardcoded)
3. Overlay analysis (if reusing existing address)
4. IRQ safety verification (if used in or with IRQ code)

**Any ZP usage change** requires:
1. Review of affected modules
2. Verification of lifetime assumptions
3. Update of CartZpMap.inc documentation

### 11.3 Audit Trail

**ZP_INVENTORY.md** (Sprint 9) will serve as the audit trail:
- All current ZP usage documented
- Hotspots identified (multi-module usage, IRQ conflicts)
- Compliance gaps noted
- Remediation plan for non-compliant code

---

## 12. Examples and Anti-Patterns

### 12.1 Good Example: API Parameter

```assembly
; ============================================================
; LoadFileBySize API Parameters
; ============================================================
; Category: API
; Lifetime: During LoadFileBySize call only
; Owner: LoadFileBySize (CartLibHi.s)
; IRQ Safety: IRQ-unsafe (mainline only)
; Usage: Caller sets size, LoadFileBySize consumes
ZP_LF_API_SIZE0 = $80
ZP_LF_API_SIZE1 = $81
ZP_LF_API_SIZE2 = $82
ZP_LF_API_SIZE3 = $83

; Caller code:
JSR IRQ_GetInfoForFile
LDA FileSize0
STA ZP_LF_API_SIZE0    ; ✅ Using symbolic name
; ...
JSR LoadFileBySize
; ZP_LF_API_SIZE0 now invalid (LoadFileBySize consumed it)
```

### 12.2 Bad Example: Hardcoded Address

```assembly
; ❌ WRONG: Hardcoded ZP address
LDA #$10
STA $80        ; What is $80? Who owns it? Lifetime?

; ✅ CORRECT: Symbolic name
LDA #$10
STA ZP_LF_API_SIZE0  ; Clear meaning, documented in CartZpMap.inc
```

### 12.3 Good Example: IRQ Safety

```assembly
; IRQ Handler (writes status)
ISR:
    LDA #$01
    STA ZP_IRQ_STATE_STATUS    ; ✅ IRQ-safe (IRQ exclusive)
    RTI

; Mainline code (reads status)
@Wait:
    LDA ZP_IRQ_STATE_STATUS    ; ✅ Safe (read-only polling)
    BEQ @Wait
```

### 12.4 Bad Example: IRQ Race Condition

```assembly
; Mainline code
LDA #$12
STA ZP_SHARED       ; ❌ WRONG: IRQ could interrupt here!
LDA #$34
STA ZP_SHARED+1

; IRQ Handler
ISR:
    LDA #$FF
    STA ZP_SHARED   ; ❌ WRONG: Overwrites mainline data!
    RTI
```

### 12.5 Good Example: Shadow RAM

```assembly
; RAM storage (permanent)
MenuState:
    .MenuIndex .byte ?

; ZP working copy (temporary)
; Category: WORK
; Lifetime: During menu operation
; Shadow: MenuState.MenuIndex
; IRQ Safety: IRQ-unsafe
ZP_MENU_WORK_INDEX = $FB

; Menu entry (load shadow)
MenuEntry:
    LDA MenuState.MenuIndex
    STA ZP_MENU_WORK_INDEX     ; ✅ Load from RAM
    ; ... use ZP_MENU_WORK_INDEX ...

; Menu exit (save shadow)
MenuExit:
    LDA ZP_MENU_WORK_INDEX
    STA MenuState.MenuIndex    ; ✅ Save to RAM
    RTS
```

---

## 13. Summary of Key Principles

1. **Zero Page is Scarce**: Treat as critical resource, document ownership and lifetime
2. **Categorize Semantically**: API, STATE, TMP, WORK (clear purpose)
3. **IRQ Separation**: Dedicated IRQ ZP, no shared TMP/WORK with mainline
4. **Shadow RAM**: Long-lived state lives in RAM, ZP is working copy
5. **Explicit Overlays**: Document temporal reuse, ensure lifetimes don't overlap
6. **Single Source of Truth**: CartZpMap.inc defines all ZP, other files include it
7. **Naming Discipline**: `ZP_<MODULE>_<CATEGORY>_<DESCRIPTION>` convention
8. **Mandatory Documentation**: Category, lifetime, owner, IRQ safety for every ZP variable

---

**Sprint Implementation Status**:
- Sprint 8: ✅ Guidelines documented (this document)
- Sprint 9: ✅ Current usage audited against these principles
- Sprint 10: ✅ CartZpMap.inc restructured for clarity
- Sprint 11: ✅ Variables renamed to follow conventions

**Last Updated**: 2025-12-27 (Sprints 8-11 Complete)
**Status**: CANONICAL
**Authority**: This document is normative. All ZP usage must comply.
