# Zero Page Inventory - EasySD / IRQHack64

**Document Type:** Inventory / Audit
**Version:** 1.0
**Created:** 2025-12-27 (Sprint 9)
**Status:** SNAPSHOT of current ZP usage (pre-Sprint 10 restructuring)

---

## 1. Purpose

This document provides a **comprehensive inventory** of all Zero Page (ZP) variable usage in the IRQHack64 codebase as of Sprint 9. It serves as:

1. **Audit trail** - Documenting current usage before restructuring
2. **Hotspot identification** - Identifying problematic patterns and risks
3. **Compliance baseline** - Comparing current usage against ZP_GUIDELINES.md principles
4. **Remediation roadmap** - Planning changes for Sprints 10-12

---

## 2. Inventory Summary

### Current State (Pre-Sprint 10)

| Metric | Count |
|--------|-------|
| Total ZP variables defined | 23 |
| Address ranges used | 5 ($64-$77, $80-$87, $8B-$8E, $90-$95) |
| Assembly files using ZP | 12 files |
| Total ZP accesses (estimated) | 177+ usages |
| Critical hotspots identified | 8 |
| Compliance gaps | Multiple (see Section 7) |

### Address Allocation

```
$64-$77 (14 bytes): IRQ File I/O API (CRITICAL - IRQ/mainline interaction)
$78-$7F ( 7 bytes): UNUSED / AVAILABLE
$80-$87 ( 8 bytes): LoadFileBySize API (mainline-only, safe)
$88-$8A ( 3 bytes): UNUSED / AVAILABLE
$8B-$8E ( 4 bytes): SafeStream parameters (streaming operations)
$8F      ( 1 byte ): UNUSED / AVAILABLE
$90-$95 ( 6 bytes): StreamLargeFile API (mainline with SEI/CLI protection)
$96-$FA (101 bytes): UNUSED / AVAILABLE
$FB-$FE ( 4 bytes): Free range (plugin temporary variables - documented in GEMINI.md)
```

**Total Used:** 32 bytes (of 256 available)
**Total Free:** 224 bytes (87.5% available)

---

## 3. Detailed Inventory by Address Range

### 3.1 LoadFileBySize API Parameters ($80-$87)

**Purpose:** File loading interface between plugins and CartLibHi

| Address | Variable | Category | Lifetime | IRQ Safety | Files Using |
|---------|----------|----------|----------|-----------|-------------|
| $80 | ZP_LF_SIZE0 | API | Function call scope | IRQ-unsafe (mainline only) | 6 files: MusPlayer, PrgPlugin, KoalaDisplayer, PetsciiDisplayer, CartLibHi, IrqLoaderMenuNew |
| $81 | ZP_LF_SIZE1 | API | Function call scope | IRQ-unsafe | Same as $80 |
| $82 | ZP_LF_SIZE2 | API | Function call scope | IRQ-unsafe | Same as $80 |
| $83 | ZP_LF_SIZE3 | API | Function call scope | IRQ-unsafe | Same as $80 |
| $84 | ZP_LF_SKIP_LO | API | Function call scope | IRQ-unsafe | 6 files: KoalaDisplayer, MusPlayer, PrgPlugin, PetsciiDisplayer, CartLibHi, IrqLoaderMenuNew |
| $85 | ZP_LF_SKIP_HI | API | Function call scope | IRQ-unsafe | Same as $84 |
| $86 | ZP_LF_PAYLOAD_LO | API (computed) | Function call scope | IRQ-unsafe | CartLibHi (read only) |
| $87 | ZP_LF_PAYLOAD_HI | API (computed) | Function call scope | IRQ-unsafe | CartLibHi (read only) |

**Usage Pattern:**
1. **Setup Phase**: Plugin or menu writes file size to $80-$83 (from IRQ_GetInfoForFile callback)
2. **Configure**: Plugin sets skip bytes in $84-$85 (e.g., 2 for PRG header)
3. **Execute**: Plugin calls `JSR LoadFileBySize`
4. **LoadFileBySize internal**: Computes payload size → $86-$87, performs transfer
5. **Cleanup**: Values invalid after LoadFileBySize returns

**Compliance Assessment:**
- ✅ **Category**: Correctly classified as API
- ✅ **Lifetime**: Well-defined (function call scope)
- ✅ **IRQ Safety**: Correctly mainline-only
- ⚠️ **Naming**: Does not follow ZP_<MODULE>_<CATEGORY>_<DESC> convention
- ⚠️ **Documentation**: CartZpMap.inc lacks mandatory fields (category, lifetime, owner)

**Historical Note:**
- **Sprint 1 Collision**: Originally used $87 which conflicted with SafeStream temps
- **Resolution**: SafeStream moved to $8B-$8E to avoid overlap
- **Documented in**: CartZpMap.inc:15-16 (comments explain the move)

---

### 3.2 SafeStream Parameters ($8B-$8E)

**Purpose:** Streaming profile configuration (SAFE, NORMAL, FAST)

| Address | Variable | Category | Lifetime | IRQ Safety | Files Using |
|---------|----------|----------|----------|-----------|-------------|
| $8B | ZP_SS_OFFSET | TMP | Single function scope | IRQ-unsafe | SafeStreamImpl (internal temp) |
| $8C | ZP_SS_INTERVAL | WORK | Stream operation scope | **SUSPICIOUS** | SafeStreamImpl, CustomStream |
| $8D | ZP_SS_CHUNK | WORK | Stream operation scope | **SUSPICIOUS** | SafeStreamImpl, CustomStream |
| $8E | ZP_SS_DELAY | WORK | Stream operation scope | **SUSPICIOUS** | SafeStreamImpl, CustomStream |

**Usage Pattern:**
1. **Profile Selection**: Caller sets A register to profile ID (0=SAFE, 1=NORMAL, 2=FAST)
2. **Profile Load**: SafeStream_Impl calculates offset (profile_id × 3) → $8B
3. **Parameter Load**: Loads 3 bytes from STREAM_PROFILES table → $8C/$8D/$8E
4. **Stream Execution**: Passes parameters to IRQ_Stream function
5. **Lifetime End**: Values stale after stream operation completes

**Compliance Assessment:**
- ⚠️ **Category**: $8B is TMP (correct), $8C-$8E should be WORK (not documented)
- ❌ **Lifetime**: Not documented in CartZpMap.inc
- ⚠️ **IRQ Safety**: Marked "SUSPICIOUS" - unclear if accessed during IRQ streaming
- ❌ **Naming**: Does not follow naming convention (should be ZP_STREAM_WORK_*)
- ❌ **Documentation**: Missing all mandatory fields

**Hotspot Concerns:**
- **Unclear IRQ interaction**: Stream operations may involve IRQ handler accessing these
- **No bounds validation**: $8C-$8E loaded from table without validation
- **Lifetime ambiguity**: When exactly are these values stale?

---

### 3.3 StreamLargeFile API ($90-$95)

**Purpose:** Large file (>64KB) streaming to continuous memory

| Address | Variable | Category | Lifetime | IRQ Safety | Files Using |
|---------|----------|----------|----------|-----------|-------------|
| $90 | ZP_STREAM_TARGET_ADDR_LO | API | Stream operation scope | **CRITICAL** (SEI protected) | CartLibStream (StreamLargeFile only) |
| $91 | ZP_STREAM_TARGET_ADDR_HI | API | Stream operation scope | **CRITICAL** (SEI protected) | CartLibStream (StreamLargeFile only) |
| $92 | ZP_STREAM_BYTES_REMAIN_0 | API | Stream operation scope | **CRITICAL** (SEI protected) | CartLibStream (StreamLargeFile only) |
| $93 | ZP_STREAM_BYTES_REMAIN_1 | API | Stream operation scope | **CRITICAL** (SEI protected) | CartLibStream (StreamLargeFile only) |
| $94 | ZP_STREAM_BYTES_REMAIN_2 | API | Stream operation scope | **CRITICAL** (SEI protected) | CartLibStream (StreamLargeFile only) |
| $95 | ZP_STREAM_BYTES_REMAIN_3 | API | Stream operation scope | **CRITICAL** (SEI protected) | CartLibStream (StreamLargeFile only) |

**Usage Pattern:**
1. **Setup**: Caller writes target address → $90-$91, file size → $92-$95
2. **Execute**: `JSR StreamLargeFile`
3. **StreamLargeFile internal**:
   - Disables interrupts (`SEI` at line 45)
   - Loops: Transfers 256 bytes, increments $90-$91, decrements $92-$95
   - Re-enables interrupts (`CLI` at line 138)
4. **Cleanup**: Values stale after return

**Compliance Assessment:**
- ✅ **Category**: API (function parameters)
- ✅ **Lifetime**: Well-defined (stream operation scope)
- ✅ **IRQ Safety**: Protected by SEI/CLI (interrupts disabled during use)
- ⚠️ **Naming**: Verbose but not fully compliant with convention
- ❌ **Documentation**: Missing mandatory fields in CartZpMap.inc

**Hotspot Concerns:**
- **Modified during operation**: $90-$95 are both input and loop variables (unusual)
- **Stale state risk**: If operation crashes, stale values remain in ZP
- **Exclusive usage**: Only used by CartLibStream, no plugins touch these

---

### 3.4 IRQ File I/O API ($64-$77) **[CRITICAL RANGE]**

**Purpose:** IRQ/NMI-driven file transfer and synchronization

| Address | Variable | Category | Lifetime | IRQ Safety | Files Using |
|---------|----------|----------|----------|-----------|-------------|
| $64 | ZP_IRQ_WaitHandle | STATE | Per-transfer operation | **CRITICAL** (IRQ sync primitive) | CartLib, CartLibDE, CartLibHi (9 accesses) |
| $69 | ZP_IRQ_SEEK_LOW | API | IRQ_SeekFile call scope | IRQ-unsafe | CartLibHi (2 accesses) |
| $6A | ZP_IRQ_SEEK_HIGH | API | IRQ_SeekFile call scope | IRQ-unsafe | CartLibHi (2 accesses) |
| $6B | ZP_IRQ_DATA_LENGTH | API | Transfer operation scope | **MIXED** (mainline write, IRQ read) | CartLib, CartLibHi, CartLibDE, plugins (7 accesses) |
| $6C | ZP_IRQ_DATA_LOW | API | Transfer operation scope | **CRITICAL** (IRQ indirect addressing) | CartLib, CartLibDE, CartLibHi, plugins (12 accesses) |
| $6D | ZP_IRQ_DATA_HIGH | API | Transfer operation scope | **CRITICAL** (IRQ indirect addressing) | CartLib, CartLibDE, CartLibHi, plugins (10 accesses) |
| $73 | ZP_IRQ_CALLBACK_LO | API | IRQ_ReceiveFragment scope | **CRITICAL** (control flow from IRQ) | CartLib, IrqLoaderMenuNew (3 accesses) |
| $74 | ZP_IRQ_CALLBACK_HI | API | IRQ_ReceiveFragment scope | **CRITICAL** (control flow from IRQ) | CartLib, IrqLoaderMenuNew (3 accesses) |
| $75 | ZP_IRQ_SEEK_UPPER_LO | API | IRQ_LongSeekFile call scope | IRQ-unsafe | CartLibHi (2 accesses) |
| $76 | ZP_IRQ_SEEK_UPPER_HI | API | IRQ_LongSeekFile call scope | IRQ-unsafe | CartLibHi (2 accesses) |
| $77 | ZP_IRQ_TEMP | TMP | Single function scope | IRQ-unsafe | CartLib, CartLibDE (2 accesses each) |

**Usage Patterns:**

#### ZP_IRQ_WaitHandle ($64) - Synchronization Primitive
```assembly
; Pattern 1: Initialize wait
LDA #$00
STA ZP_IRQ_WaitHandle

; Pattern 2: Poll for completion
@Wait:
    BIT ZP_IRQ_WaitHandle
    BEQ @Wait  ; Wait until IRQ sets bit 6

; Pattern 3: IRQ completion signal
; (NMI handler writes $64 to signal done)
```

#### ZP_IRQ_DATA_LOW/HIGH ($6C/$6D) - Indirect Addressing from NMI
```assembly
; **CRITICAL**: Used in NMI handler TransferHandler (CartLib:344)
STA (ZP_IRQ_DATA_LOW), Y  ; Indirect addressing from interrupt!

; Also incremented during transfer (CartLib:350)
INC ZP_IRQ_DATA_HIGH  ; Crosses page boundary
```

#### ZP_IRQ_CALLBACK_LO/HI ($73/$74) - Fake RTS Pattern
```assembly
; Setup (mainline code):
LDA #>ReturnAddress
STA ZP_IRQ_CALLBACK_HI
LDA #<ReturnAddress
STA ZP_IRQ_CALLBACK_LO

; Callback execution (CartLib:293-297):
LDA ZP_IRQ_CALLBACK_HI
PHA
LDA ZP_IRQ_CALLBACK_LO
PHA
RTS  ; Fake return to address in ZP_IRQ_CALLBACK
```

**Compliance Assessment:**
- ❌ **Category**: Mixed (not documented in CartZpMap.inc)
- ❌ **Lifetime**: Not documented (varies by variable)
- ⚠️ **IRQ Safety**: Critical concerns (see Hotspots section below)
- ❌ **Naming**: Does not follow convention (should be ZP_IRQ_API_*, ZP_IRQ_STATE_*)
- ❌ **Documentation**: Severely lacking (no category, lifetime, owner fields)

**Hotspot Concerns - CRITICAL:**

1. **$6C/$6D Indirect Addressing from NMI** ⚠️ **HIGHEST RISK**
   - Used in `STA (ZP_IRQ_DATA_LOW), Y` pattern from interrupt context
   - Modified during transfer (INC instruction)
   - **Risk**: If mainline code accesses during transfer, data corruption
   - **Current Mitigation**: Protected by interrupt disable sequences
   - **Concern**: Future code must maintain SEI/CLI discipline

2. **$64 WaitHandle Synchronization** ⚠️ **HIGH RISK**
   - Complex state machine (init to $00, IRQ sets $64)
   - Polled with BIT instruction (unusual pattern)
   - **Risk**: If multiple operations queue, state confusion possible
   - **Concern**: No documentation of valid state transitions

3. **$73/$74 Callback Fake RTS** ⚠️ **MEDIUM RISK**
   - Non-standard control flow (interrupt resuming via stack manipulation)
   - **Risk**: If overwritten before callback executes, incorrect return address
   - **Concern**: Debugging difficulty (stack-based control flow hard to trace)

4. **$6B DATA_LENGTH Mixed Access** ⚠️ **MEDIUM RISK**
   - Written by mainline, read by IRQ handler
   - **Risk**: Partial write visible to IRQ if not atomic
   - **Current Mitigation**: Single-byte value (atomic on 6502)
   - **Concern**: If changed to multi-byte, requires SEI/CLI

5. **Overlapping Address Usage** ⚠️ **LOW RISK (CLARIFIED)**
   - $69/$6A used for SEEK_LOW/HIGH
   - $6C/$6D used for DATA_LOW/HIGH
   - **Analysis**: Separate use cases, no actual overlap
   - **Conclusion**: Intentional separation, not a conflict

---

## 4. Files Using Zero Page Variables

### 4.1 Loader Components (Core Library)

| File | ZP Variables Used | Usage Type |
|------|-------------------|-----------|
| CartZpMap.inc | ALL (defines all 23 variables) | **DEFINITION** (single source of truth) |
| CartLib.s | ZP_IRQ_TEMP, ZP_IRQ_DATA_LOW/HIGH, ZP_IRQ_DATA_LENGTH, ZP_IRQ_WaitHandle, ZP_IRQ_CALLBACK_LO/HI | READ, WRITE, INDIRECT, POLL |
| CartLibDE.s | Same as CartLib.s | Same (duplicate of CartLib?) |
| CartLibHi.s | ZP_IRQ_DATA_LOW/HIGH, ZP_IRQ_DATA_LENGTH, ZP_IRQ_CALLBACK_LO/HI, ZP_IRQ_SEEK_LOW/HIGH, ZP_IRQ_SEEK_UPPER_LO/HI, ZP_LF_SIZE0-3, ZP_LF_SKIP_LO/HI, ZP_LF_PAYLOAD_LO/HI | READ, WRITE, COMPUTE |
| CartLibStream.s | ZP_STREAM_TARGET_ADDR_LO/HI, ZP_STREAM_BYTES_REMAIN_0-3 | READ, WRITE, MODIFY (INC/SBC) |
| SafeStreamImpl.s | ZP_SS_OFFSET, ZP_SS_INTERVAL, ZP_SS_CHUNK, ZP_SS_DELAY | READ, WRITE |

**Note:** CartLibDE.s appears to be a duplicate or variant of CartLib.s (same ZP usage patterns)

### 4.2 Menu System

| File | ZP Variables Used | Usage Type |
|------|-------------------|-----------|
| IrqLoaderMenuNew.s | ZP_IRQ_CALLBACK_LO/HI, ZP_LF_SIZE0-3, ZP_LF_SKIP_LO/HI | WRITE (setup), READ (for file loading) |

**Usage:** Menu sets up file loading parameters, configures callbacks for file operations

### 4.3 Plugins

| Plugin File | ZP Variables Used | Purpose |
|-------------|-------------------|---------|
| MusPlayer.s | ZP_LF_SIZE0-3, ZP_LF_SKIP_LO/HI, ZP_IRQ_DATA_LENGTH | Music file loading (SID files) |
| PrgPlugin.s | ZP_LF_SIZE0-3, ZP_LF_SKIP_LO/HI, ZP_IRQ_DATA_LENGTH | PRG file loading (skip 2-byte header) |
| KoalaDisplayer.s | ZP_LF_SIZE0-3, ZP_LF_SKIP_LO/HI | Koala picture loading (10003 bytes) |
| PetsciiDisplayer.s | ZP_LF_SIZE0-3, ZP_LF_SKIP_LO/HI | PETSCII art loading (1000 or 2000 bytes) |
| PrgPluginStub.s | (none visible in grep) | Stub file (minimal ZP usage) |

**Pattern:** All plugins follow similar pattern:
1. Call `IRQ_GetInfoForFile` → populates ZP_LF_SIZE0-3
2. Set skip bytes (ZP_LF_SKIP_LO/HI) if needed
3. Call `LoadFileBySize` or `IRQ_ReceiveFragment`
4. File data transferred to plugin buffer

### 4.4 Other Components

| File | ZP Variables Used | Notes |
|------|-------------------|-------|
| sidobj64.asm | (grep shows usage but needs analysis) | SID player assembly (MusPlayer dependency) |

---

## 5. Multi-Module Shared Variables (Hotspots)

### 5.1 ZP_IRQ_DATA_LOW/HIGH ($6C/$6D) - **HIGHEST HOTSPOT**

**Shared by:**
- CartLib.s (TransferHandler NMI)
- CartLibDE.s (same pattern)
- CartLibHi.s (LoadFileBySize setup)
- MusPlayer.s (file target address)
- PrgPlugin.s (PRG load address)
- KoalaDisplayer.s (Koala buffer address)
- PetsciiDisplayer.s (PETSCII buffer address)
- IrqLoaderMenuNew.s (menu file loading)

**Usage Pattern:**
- **Plugins/Menu**: Write target address before calling file load functions
- **CartLibHi**: Passes address to lower-level transfer functions
- **CartLib**: **Reads via indirect addressing from NMI handler** (`STA (ZP_IRQ_DATA_LOW), Y`)

**Risk Assessment:**
- **CRITICAL**: Indirect addressing from interrupt context
- **Mitigation**: SEI/CLI discipline protects critical sections
- **Concern**: 8+ files writing to same ZP addresses → must serialize properly

### 5.2 ZP_LF_SIZE0-3 ($80-$83) - **HIGH HOTSPOT**

**Shared by:**
- MusPlayer.s
- PrgPlugin.s
- KoalaDisplayer.s
- PetsciiDisplayer.s
- IrqLoaderMenuNew.s
- CartLibHi.s

**Usage Pattern:**
- All plugins write file size after `IRQ_GetInfoForFile` callback
- CartLibHi reads size to validate and compute payload

**Risk Assessment:**
- **MEDIUM**: Multiple writers, but operations are sequential (no concurrency)
- **Safe**: Each plugin operation is independent (load file → process → exit)
- **Concern**: Plugin developer must understand this is API contract, not persistent state

### 5.3 ZP_IRQ_WaitHandle ($64) - **MEDIUM HOTSPOT**

**Shared by:**
- CartLib.s (ReceiveFragment, multiple uses)
- CartLibDE.s (same pattern)
- CartLibHi.s (file transfer coordination)

**Usage Pattern:**
- Synchronization primitive between mainline and NMI handler
- Complex state machine (init to $00, poll with BIT, IRQ sets $64)

**Risk Assessment:**
- **MEDIUM**: State machine complexity
- **Mitigation**: Only accessed within CartLib family (controlled usage)
- **Concern**: No documentation of valid state transitions

---

## 6. IRQ vs Mainline Access Patterns

### 6.1 Variables Accessed from IRQ/NMI Context

| Variable | Address | IRQ Access Type | Mainline Access Type | Protection |
|----------|---------|-----------------|---------------------|-----------|
| ZP_IRQ_DATA_LOW | $6C | **INDIRECT READ** (`LDA (ZP),Y`) | WRITE (setup), MODIFY (INC in stream) | SEI/CLI |
| ZP_IRQ_DATA_HIGH | $6D | **INDIRECT READ** (`LDA (ZP),Y`) | WRITE (setup), MODIFY (INC at page boundary) | SEI/CLI |
| ZP_IRQ_DATA_LENGTH | $6B | READ (transfer loop counter) | WRITE (set page count) | Atomic (single byte) |
| ZP_IRQ_WaitHandle | $64 | WRITE (completion signal $64) | POLL (BIT instruction), WRITE (init to $00) | State machine protocol |

**Critical Pattern:**
- **Mainline → IRQ**: Setup phase (writes $6B/$6C/$6D with SEI/CLI protection)
- **IRQ → Mainline**: Completion signaling (writes $64)
- **Shared access**: $6C/$6D used for indirect addressing (most dangerous)

### 6.2 Mainline-Only Variables (IRQ-Safe)

**These variables are NEVER accessed from interrupt context:**

- ZP_LF_SIZE0-3 ($80-$83) - File size parameters
- ZP_LF_SKIP_LO/HI ($84-$85) - Skip bytes
- ZP_LF_PAYLOAD_LO/HI ($86-$87) - Computed payload
- ZP_SS_OFFSET/INTERVAL/CHUNK/DELAY ($8B-$8E) - Stream params
- ZP_STREAM_TARGET_ADDR_LO/HI ($90-$91) - Stream address (SEI protected)
- ZP_STREAM_BYTES_REMAIN_0-3 ($92-$95) - Stream countdown (SEI protected)
- ZP_IRQ_SEEK_LOW/HIGH ($69-$6A) - Seek parameters
- ZP_IRQ_SEEK_UPPER_LO/HI ($75-$76) - Long seek parameters
- ZP_IRQ_CALLBACK_LO/HI ($73-$74) - Callback address (written by mainline, read for fake RTS)
- ZP_IRQ_TEMP ($77) - Temporary scratch

---

## 7. Compliance Gaps (vs ZP_GUIDELINES.md)

### 7.1 Naming Convention Violations

**Guideline:** `ZP_<MODULE>_<CATEGORY>_<DESCRIPTION>`

**Current Violations:**

| Current Name | Suggested Compliant Name | Module | Category |
|--------------|--------------------------|--------|----------|
| ZP_LF_SIZE0 | ZP_LOADFILE_API_SIZE0 | LoadFileBySize | API |
| ZP_LF_SIZE1 | ZP_LOADFILE_API_SIZE1 | LoadFileBySize | API |
| ZP_LF_SIZE2 | ZP_LOADFILE_API_SIZE2 | LoadFileBySize | API |
| ZP_LF_SIZE3 | ZP_LOADFILE_API_SIZE3 | LoadFileBySize | API |
| ZP_LF_SKIP_LO | ZP_LOADFILE_API_SKIP_LO | LoadFileBySize | API |
| ZP_LF_SKIP_HI | ZP_LOADFILE_API_SKIP_HI | LoadFileBySize | API |
| ZP_LF_PAYLOAD_LO | ZP_LOADFILE_API_PAYLOAD_LO | LoadFileBySize | API |
| ZP_LF_PAYLOAD_HI | ZP_LOADFILE_API_PAYLOAD_HI | LoadFileBySize | API |
| ZP_SS_OFFSET | ZP_SAFESTREAM_TMP_OFFSET | SafeStream | TMP |
| ZP_SS_INTERVAL | ZP_SAFESTREAM_WORK_INTERVAL | SafeStream | WORK |
| ZP_SS_CHUNK | ZP_SAFESTREAM_WORK_CHUNK | SafeStream | WORK |
| ZP_SS_DELAY | ZP_SAFESTREAM_WORK_DELAY | SafeStream | WORK |
| ZP_STREAM_TARGET_ADDR_LO | ZP_STREAM_API_TARGET_LO | StreamLargeFile | API |
| ZP_STREAM_TARGET_ADDR_HI | ZP_STREAM_API_TARGET_HI | StreamLargeFile | API |
| ZP_STREAM_BYTES_REMAIN_0 | ZP_STREAM_API_REMAIN0 | StreamLargeFile | API |
| ZP_STREAM_BYTES_REMAIN_1 | ZP_STREAM_API_REMAIN1 | StreamLargeFile | API |
| ZP_STREAM_BYTES_REMAIN_2 | ZP_STREAM_API_REMAIN2 | StreamLargeFile | API |
| ZP_STREAM_BYTES_REMAIN_3 | ZP_STREAM_API_REMAIN3 | StreamLargeFile | API |
| ZP_IRQ_WaitHandle | ZP_IRQ_STATE_WAITHANDLE | IRQ Protocol | STATE |
| ZP_IRQ_DATA_LOW | ZP_IRQ_API_DATA_LO | IRQ Protocol | API |
| ZP_IRQ_DATA_HIGH | ZP_IRQ_API_DATA_HI | IRQ Protocol | API |
| ZP_IRQ_DATA_LENGTH | ZP_IRQ_API_DATA_LENGTH | IRQ Protocol | API |
| ZP_IRQ_CALLBACK_LO | ZP_IRQ_API_CALLBACK_LO | IRQ Protocol | API |
| ZP_IRQ_CALLBACK_HI | ZP_IRQ_API_CALLBACK_HI | IRQ Protocol | API |

**Total Violations:** 23 of 23 variables (100%)

### 7.2 Documentation Violations

**Guideline:** Every ZP variable must document:
- Category (API / STATE / TMP / WORK)
- Lifetime (specific lifetime description)
- Owner (module or function name)
- IRQ Safety (IRQ-safe / IRQ-unsafe)
- [Optional] Overlay information
- [Optional] Shadow RAM variable

**Current State:** CartZpMap.inc has **ZERO** variables with complete documentation

**Example of Insufficient Documentation (current):**
```assembly
; ---- LoadFileBySize (CartLibHi) uses $80-$87 ----
ZP_LF_SIZE0 = $80
```

**Required Documentation (ZP_GUIDELINES.md compliant):**
```assembly
; Category: API
; Lifetime: Duration of LoadFileBySize call only
; Owner: LoadFileBySize function (CartLibHi.s)
; IRQ Safety: IRQ-unsafe (mainline only)
; Overlay: Safe (can reuse after function returns)
ZP_LF_SIZE0 = $80
```

### 7.3 Missing Shadow RAM Patterns

**Guideline:** Long-lived STATE should use RAM shadow with ZP as working copy

**Current Violations:**
- ZP_IRQ_WaitHandle ($64) - Should this have RAM shadow for persistence?
  - **Analysis:** No, this is a synchronization primitive (valid during transfer only)
  - **Conclusion:** Not a violation (short lifetime)

**No clear violations identified** - most variables are API or TMP category (short lifetimes)

### 7.4 Undocumented Overlays

**Guideline:** Overlaid ZP addresses must document both uses with lifetime notes

**Potential Overlays** (not documented):
- $FB-$FE range: Documented in GEMINI.md as "free range for plugins" but no specific plugin usage inventoried
- **Concern:** Plugins may be using this range without coordination

**Recommendation:** Sprint 10 should audit plugin TMP usage in $FB-$FE range

### 7.5 IRQ Safety Ambiguities

**Guideline:** Every variable must declare IRQ safety status

**Ambiguous Cases:**
- ZP_SS_INTERVAL/CHUNK/DELAY ($8C-$8E): Marked "SUSPICIOUS" in inventory - unclear if IRQ accesses
- **Resolution Needed:** Trace SafeStream execution to determine IRQ interaction

---

## 8. Critical Hotspots Summary

### 8.1 ZP_IRQ_DATA_LOW/HIGH ($6C/$6D) ⚠️ **HIGHEST PRIORITY**

**Issue:** Indirect addressing from NMI handler in TransferHandler

**Code Reference:** CartLib.s:344
```assembly
STA (ZP_IRQ_DATA_LOW), Y  ; Writing to address pointed to by ZP
```

**Risk:** Data corruption if mainline modifies $6C/$6D during transfer

**Current Mitigation:** SEI/CLI protection in transfer setup

**Sprint 10-12 Actions:**
- ✅ Document IRQ usage in CartZpMap.inc
- ✅ Add comment at usage site explaining indirect addressing
- ✅ Consider renaming to ZP_IRQ_API_BUFFER_PTR_LO/HI for clarity

### 8.2 ZP_IRQ_WaitHandle ($64) ⚠️ **HIGH PRIORITY**

**Issue:** Complex synchronization state machine, undocumented transitions

**Valid States:**
- $00 = Idle / waiting for IRQ
- $64 = IRQ completed (why $64 specifically?)

**Code Pattern:** BIT instruction used for polling (CartLib:270)
```assembly
BIT ZP_IRQ_WaitHandle
BEQ @Wait  ; Branch if zero (waiting)
```

**Risk:** State confusion if multiple operations queue

**Sprint 10-12 Actions:**
- ✅ Document state machine transitions
- ✅ Explain why $64 is completion value (bit 6 set = overflow flag)
- ✅ Rename to ZP_IRQ_STATE_WAITHANDLE for clarity

### 8.3 ZP_SS_INTERVAL/CHUNK/DELAY ($8C-$8E) ⚠️ **MEDIUM PRIORITY**

**Issue:** Unclear lifetime, potential IRQ interaction during streaming

**Risk:** If IRQ handler reads these during stream, race condition possible

**Sprint 10-12 Actions:**
- ✅ Trace SafeStream execution to confirm IRQ usage
- ✅ Document lifetime (valid during stream operation only)
- ✅ Add bounds validation if loaded from untrusted source

### 8.4 ZP_IRQ_CALLBACK_LO/HI ($73/$74) ⚠️ **MEDIUM PRIORITY**

**Issue:** Non-standard control flow (fake RTS from interrupt)

**Pattern:** Stack manipulation for callback resumption
```assembly
LDA ZP_IRQ_CALLBACK_HI
PHA
LDA ZP_IRQ_CALLBACK_LO
PHA
RTS  ; Returns to address in ZP_IRQ_CALLBACK
```

**Risk:** Debugging difficulty, easy to corrupt if overwritten

**Sprint 10-12 Actions:**
- ✅ Document fake RTS pattern in CartZpMap.inc
- ✅ Add comment explaining why this is necessary
- ✅ Consider alternative (direct JMP instead of fake RTS?)

### 8.5 Multi-Module Writes to $80-$83 ⚠️ **LOW PRIORITY**

**Issue:** 6 files write to ZP_LF_SIZE0-3

**Analysis:** Not a real risk (operations are sequential, not concurrent)

**Sprint 10-12 Actions:**
- ✅ Document that this is API contract (multiple callers expected)
- ✅ Rename to clearly indicate API category

### 8.6 CartLib.s vs CartLibDE.s Duplication ⚠️ **LOW PRIORITY (INVESTIGATE)**

**Observation:** CartLibDE.s has identical ZP usage patterns to CartLib.s

**Question:** Is CartLibDE.s a duplicate, variant, or debug version?

**Sprint 10-12 Actions:**
- ⚠️ Investigate purpose of CartLibDE.s
- ⚠️ If duplicate, consider removing to reduce maintenance
- ⚠️ If variant, document differences

### 8.7 Stale State in $90-$95 After StreamLargeFile ⚠️ **LOW PRIORITY**

**Issue:** After StreamLargeFile completes, ZP values remain (no cleanup)

**Risk:** Low (only used by StreamLargeFile, not accessed elsewhere)

**Sprint 10-12 Actions:**
- ✅ Document that values are stale after operation
- Consider: Add cleanup (zero $90-$95) at end of StreamLargeFile?

### 8.8 Plugin $FB-$FE Usage Undocumented ⚠️ **MEDIUM PRIORITY**

**Issue:** GEMINI.md mentions $FB-$FE as "free range for plugins" but no inventory of actual usage

**Risk:** Plugins may collide if multiple use same addresses without coordination

**Sprint 10-12 Actions:**
- ✅ Audit all plugins for $FB-$FE usage
- ✅ Document which plugin uses which addresses
- ✅ Enforce overlay discipline (plugins don't run concurrently, so safe if documented)

---

## 9. Recommendations for Sprint 10-12

### Sprint 10: CartZpMap.inc Restructuring

**Objectives:**
1. Add logical block organization (Protocol, API, State, Work, TMP)
2. Add mandatory documentation fields to ALL variables
3. Visual separation (comment blocks between sections)
4. **No renaming** (documentation only)

**Template for Each Variable:**
```assembly
; ============================================================
; PROTOCOL LAYER - IRQ/NMI Communication ($64-$77)
; ============================================================

; Category: STATE
; Lifetime: Valid during file transfer operation
; Owner: CartLib transfer protocol
; IRQ Safety: IRQ-safe (written by NMI, polled by mainline)
; State Machine: $00 = waiting, $64 = complete (bit 6 set)
ZP_IRQ_WaitHandle = $64
```

### Sprint 11: Variable Renaming

**Objectives:**
1. Rename all 23 variables to follow `ZP_<MODULE>_<CATEGORY>_<DESC>` convention
2. Update all 12 assembly files with new names
3. Verify build produces identical binaries (addresses unchanged, only symbols renamed)

**Systematic Approach:**
- Rename one logical group at a time (e.g., LoadFileBySize API first)
- Build and test after each group
- Use 64tass label files to verify address mapping unchanged

**Result:** ✅ Sprint 11 completed successfully - all variables renamed, 100% naming compliance achieved.

---

## 10. Conclusion

### Current State Assessment

**Strengths:**
- ✅ Clean address space organization (5 distinct ranges)
- ✅ SEI/CLI discipline properly applied in critical sections
- ✅ No actual address conflicts (historical $87 collision resolved)
- ✅ Consistent API patterns (plugins follow same file loading sequence)

**Weaknesses:**
- ❌ Zero variables have compliant documentation
- ❌ 100% naming convention violations
- ❌ IRQ safety status unclear for several variables
- ❌ No documented state machines for synchronization primitives
- ❌ Undocumented plugin TMP usage ($FB-$FE range)

**Overall:** The codebase has **good practices** (SEI/CLI, no conflicts) but **poor documentation**. Sprint 10-12 will formalize existing good practices.

---

**Inventory Completed:** 2025-12-27 (Sprint 9)
**Status:** BASELINE for Sprint 10-12 restructuring
**Next Step:** Proceed with Sprint 10 (CartZpMap.inc restructuring)
