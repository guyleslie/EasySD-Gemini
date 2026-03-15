# Canonical Memory Map - EasySD (Normative)

**Document Type:** Normative (Architectural Specification)
**Version:** 2.2
**Created:** 2025-12-29 (Sprint A.2.1)
**Last Updated:** 2026-03-15 (v2.3 — MultiLoad plugin, ResidentLoader memory regions)
**Status:** CANONICAL - All code MUST conform to this memory layout
**Reference:** ARCHITECTURE_CONSOLIDATION_PLAN.md Sprint A.2, A.3.0 (archived)

---

## Purpose and Scope

This document defines the **normative memory architecture** for the EasySD project. It documents the Zero Page pointer-based API design, program categorization (Type A plugins vs Type B standalone apps), and recommended memory layout practices.

**This document is normative**: All code MUST use the CartLib API as specified. Memory buffer placement is flexible (via ZP pointers), but code MUST follow the architectural patterns described in this document.

**Version 2.0 Changes:** This version reflects architectural research findings from Sprint A.3.0, correcting incorrect assumptions about fixed buffer addresses in v1.0. See Section 8 (Revision History) for details.

---

## 1. Type A Plugin Memory Architecture

**Note:** This section applies to **Type A plugins** only (programs loaded at $C000+ by the menu). Type B standalone applications ($080E) are documented in Section 4.

### 1.1 Transfer Buffer Architecture (Zero Page Pointer-Based)

**API Design:** The CartLib API uses **Zero Page pointers** ($69-$6A or $6C-$6D) to access transfer buffers. Plugins may place buffers **anywhere in available memory**.

**ZP API Parameters:**
- `ZP_IRQ_API_DATA_LO` ($69 or $6C) - Buffer address low byte
- `ZP_IRQ_API_DATA_HI` ($6A or $6D) - Buffer address high byte
- `ZP_IRQ_API_DATA_LENGTH` ($6B) - Transfer length in 256-byte pages

**Typical Buffer Locations (Assembler Auto-Placement):**

| Plugin | Buffer Symbol | Auto-Placed Address | Size |
|--------|---------------|---------------------|------|
| PrgPlugin | GENERALBUFFER | $D032 | 256 bytes |
| KoalaDisplayer | READBUFFER | $C770 | Variable |
| KoalaDisplayer | KOALA_INFO_BUFFER | $C670 | Variable |
| PetsciiDisplayer | READBUFFER | $C672 | Variable |
| WavPlayer | READBUFFER | $C700 | Variable |

**Constraints:**
- Buffer MUST NOT overlap with plugin code ($C000-$C6xx typical range)
- Buffer MUST NOT overlap with screen memory ($0400-$07FF, $CC00-$CFFF if used)
- Buffer MUST NOT overlap with menu memory ($080E-$0FFF region)
- Buffer MUST be in RAM (not ROM regions $A000-$BFFF, $E000-$FFFF)

**Buffer Volatility:**
- Content is NOT preserved across API calls
- Ownership: Caller owns during API call, INVALID after return
- After API return, buffer content is STALE (may contain garbage)

**Recommended Symbol Definition:**

While the CartMemoryMap.inc file defines `TRANSFER_BUFFER_ADDR = $C000` for reference, plugins are NOT required to use this address. The symbol exists for documentation purposes and optional standardization, but **assembler auto-placement is acceptable and widely used**.

---

### 1.2 NMI Handler Region (Optional)

**Recommended Address Range:** `$C1A0-$CEB6` (3351 bytes)

**Purpose:** Optional code region for NMI (Non-Maskable Interrupt) handlers.

**Characteristics:**
- **Optional:** Most plugins do NOT use NMI handlers
- **Usage:** Plugins with interrupt-driven data loading MAY place NMI handlers here
- **Canonical Symbols:** `NMI_HANDLER_REGION_START = $C1A0`, `NMI_HANDLER_REGION_END = $CEB6`

**Note:** This region is defined in CartMemoryMap.inc for reference, but plugins are free to place NMI code elsewhere if needed. The $C1A0 start address was chosen historically to leave space after a hypothetical $C000 buffer, but with auto-placement, this constraint no longer applies strictly.

**Actual Usage:**
- Most plugins: NO NMI handlers (use standard IRQ_ReceiveFragment API)
- BurstLoader (Type B app): Uses custom NMI handlers, but loads at $080E (not subject to plugin constraints)

---

### 1.3 Type A Plugin Layout Example (Recommended Pattern)

```assembly
;----------------------------------------------------------------------------------------------------------
; ExamplePlugin - Type A Plugin (loads at $C000+, returns to menu)
;----------------------------------------------------------------------------------------------------------
.include "../../Loader/DebugMacros.s"
.include "../../Loader/APIMacros.s"

*=$C000
PluginEntry:
    JMP Main

; ... Plugin code and data (assembler auto-places) ...

Main:
    ; Set up transfer buffer (pass buffer address to API via ZP pointer)
    #SETADDR FileBuffer, ZP_IRQ_API_DATA_LO
    LDA #1                          ; Read 1 page (256 bytes)
    STA ZP_IRQ_API_DATA_LENGTH
    JSR IRQ_ReadFileNoCallback

    ; ... plugin logic ...

    RTS                             ; Return to menu

; Transfer buffer (assembler auto-places after code, e.g., $C670)
; NO explicit ORG directive needed - auto-placement prevents conflicts
FileBuffer:
    .res 416                        ; 416 bytes for file metadata

; Compile-time safety check (optional defensive programming)
.if * > $DF00
    .error "Plugin overflow! Would overlap with I/O region ($DF00+)"
.endif
```

**Key Points:**
- Entry point at $C000 (JMP MAIN)
- Code and data auto-placed by assembler
- Buffer defined WITHOUT explicit `*=` directive (assembler places it after code)
- API called with buffer address via `#SETADDR` macro (sets ZP pointers)
- Compile-time check prevents memory overflow

---

## 2. API Usage Requirements (Type A Plugins)

### 2.1 Mandatory Requirements

**ALL Type A plugins MUST:**
1. **Use CartLib API** via ZP pointers (do NOT bypass API)
2. **Load at $C000** (entry point with `*=$C000` directive)
3. **Return to menu** via RTS (do NOT call IRQ_ExitToMenu - that's for Type B apps)
4. **Include API macros**: `.include "../../Loader/APIMacros.s"`

### 2.2 Buffer Placement Rules

**Plugins MUST:**
- Pass buffer address to API via `#SETADDR` macro or manual ZP setting
- Ensure buffers do NOT overlap with:
  - Plugin code region ($C000-$C6xx typical)
  - Screen memory ($0400-$07FF, or $CC00-$CFFF if used)
  - Menu memory ($080E-$0FFF)
  - ROM regions ($A000-$BFFF, $E000-$FFFF)

**Plugins MAY:**
- Use assembler auto-placement for buffers (recommended)
- Explicitly place buffers with `*=` directives (if needed for specific layout)
- Use CartMemoryMap.inc symbols (`TRANSFER_BUFFER_ADDR`, `NMI_HANDLER_REGION_START`) optionally

### 2.3 Forbidden Practices

**Plugins MUST NOT:**
- Assume buffer content persists across API calls (buffers are volatile)
- Call IRQ_ExitToMenu (Type B apps only)
- Overwrite menu memory ($080E+ region)
- Use hardcoded I/O addresses (use API functions instead)

### 2.4 Compile-Time Safety Checks (Recommended)

**Defensive programming:** Add compile-time checks to detect memory overflow.

```assembly
; Check plugin doesn't overflow into I/O region
.if * > $DF00
    .error "Plugin overflow! Would overlap with I/O region ($DF00+)"
.endif

; Check buffer size is sufficient
.if MYBUFFER_SIZE < 416
    .error "Buffer too small for file metadata (needs 416 bytes)!"
.endif
```

---

## 3. Memory Map Summary (Type A Plugins)

### 3.1 Typical Memory Layout

| Address Range | Purpose | Placement | Notes |
|---------------|---------|-----------|-------|
| **$C000** | Plugin entry point (JMP MAIN) | **MANDATORY** explicit `*=$C000` | Menu jumps here via `JMP (PLUGIN_LOAD_ADDR_LO)` |
| **$C003-$C6xx** | Plugin code and data | Assembler auto-placement | Exact end varies by plugin size |
| **$C670-$D0xx** | Transfer buffers (typical) | Assembler auto-placement | Actual addresses vary (see Section 1.1 table) |
| **$080E-$0FFF** | Menu code (resident) | **FORBIDDEN** for plugins | Menu remains in memory, do NOT overwrite |
| **$0400-$07FF** | Screen memory (default) | **CAUTION** if used for buffers | May conflict with display |
| **$DF00-$DFFF** | I/O region (cartridge ports) | **FORBIDDEN** | Used by CartLib API for hardware access |

### 3.2 Symbolic References (CartMemoryMap.inc)

| Symbol | Value | Purpose | Mandatory? |
|--------|-------|---------|------------|
| `TRANSFER_BUFFER_ADDR` | $C000 | Optional reference address for buffers | **NO** (auto-placement OK) |
| `TRANSFER_BUFFER_SIZE` | $01A0 (416 bytes) | Recommended minimum buffer size | Informational |
| `NMI_HANDLER_REGION_START` | $C1A0 | Optional NMI code region start | **NO** (rarely used) |
| `NMI_HANDLER_REGION_END` | $CEB6 | Optional NMI code region end | **NO** (rarely used) |
| `BURST_BUFFER_ADDR` | $A000 | BurstLoader-specific (Type B app) | **NO** (Type B only) |

**Note:** Symbols are defined for documentation and optional use, but are NOT mandatory for Type A plugins.

---

## 3.3 ResidentLoader Memory Regions (MultiLoad Plugin)

The MultiLoad plugin installs a resident hook that uses two additional memory regions outside
the standard `$C000+` plugin range. These regions exist only during multi-load game execution
(after `BOOT.PRG` has launched the game and exited the menu permanently).

| Address Range  | Symbol         | Content                                      | Notes |
|----------------|----------------|----------------------------------------------|-------|
| `$0330/$0331`  | `V_LOAD`       | Kernal LOAD vector (patched by RL_INSTALL)   | Patched to `$033C` |
| `$033C–$034F`  | `RL_STUB`      | 20-byte LOAD trampoline (`JSR RL_HANDLER`)   | Overwrites `FILE_PATH_BUF` area |
| `$035C–$035D`  | `RL_ORIG_VEC`  | Backup of original `$0330/$0331`             | Used by pass-through path |
| `$035E`        | `RL_SAVED_01`  | Saved `$01` register during hook execution   | 1 byte |
| `$E800`        | `RL_HANDLER`   | Handler entry point                          | Under Kernal ROM ($01=$35 to access) |
| `$E840`        | `RL_DIR_PATH`  | Game dir path buffer, 64 B                   | Reserved; future chdir support |
| `$E880`        | `RL_FNAME_BUF` | Assembled filename buffer, 36 B              | KERNAL name + ".PRG" |
| `$E8A4`        | `RL_FILEINFO_BUF` | FAT directory entry buffer, 32 B          | IRQ_GetInfoForFile target |
| `$E8C4`        | `RL_HDR_BUF`   | First-page read buffer, 256 B                | PRG header + first 254 data bytes |

**Dual-use of `$033C` (FILE_PATH_BUF / RL_STUB):**
During menu and plugin operation, `$033C` is `FILE_PATH_BUF` (filename buffer for CartLib).
During multi-load game execution, `$033C` is `RL_STUB` code.
The two uses are mutually exclusive and therefore safe.

**Why writes to `$E800` always go to RAM:**
The C64 write line always reaches underlying RAM regardless of the `$01` banking register.
`RL_INSTALL` copies the handler with `$01=$37` (normal); no banking switch needed during copy.
The handler is only *reachable* with `$01=$35` (Kernal ROM hidden, I/O active).

Constants for these regions are defined in `EasySD/Loader/Common/System.inc`.

---

## 4. Program Categories (Type A vs Type B)

**Critical Distinction:** The EasySD/Plugins directory contains TWO fundamentally different program types with distinct architectures.

### 4.1 Type A: True Plugins ($C000+)

**Load Address:** $C000 (or higher, as specified in PRG header)

**Loading Method:** Menu loads plugin into memory, then executes `JMP (PLUGIN_LOAD_ADDR_LO)` (indirect jump to entry point read from PRG header).

**Execution Model:**
- Plugin runs in **same C64 session** as menu
- Menu code remains **resident** at $080E-$0FFF (cohabitation)
- Plugin returns to menu via **RTS** when done

**Memory Constraints:**
- MUST NOT overwrite menu memory ($080E-$0FFF)
- MUST preserve Zero Page state used by menu
- SHOULD use assembler auto-placement for buffers (recommended)

**Examples:**
- **KernalBridge** (`EasySD/Loader/Bridges/KernalBridge/`) — KERNAL I/O bridge + large PRG loader; NOT in Plugins/
- **MultiLoad** (`EasySD/Loader/Bridges/MultiLoad/`) — Multi-load game launcher; installs a resident Kernal LOAD hook and does NOT return to menu
- **KoalaDisplayer** — Koala image viewer
- **PetsciiDisplayer** — PETSCII art viewer
- **WavPlayer** — WAV audio player
- **MusPlayer** — MUS/SID music player
- **CvdPlayer** — CVD video player (NMI-driven frame streaming)

**Source Location:** Plugins at `EasySD/Plugins/`. KernalBridge and MultiLoad at `EasySD/Loader/Bridges/` (loaded by menu as prgplugin.prg / bootplugin.prg but architecturally separate — they launch programs rather than returning to menu).

**Calling Convention:**
```assembly
; Menu side (EasySDMenu.s line 558):
JMP (PLUGIN_LOAD_ADDR_LO)       ; Jump to plugin entry point (from PRG header)

; Plugin side:
*=$C000
PluginEntry:
    JMP Main

Main:
    ; ... plugin logic ...
    RTS                          ; Return to menu
```

---

### 4.2 Type B: Standalone Applications ($080E)

**Load Address:** $080E (C64 BASIC program start address)

**Loading Method:** Arduino/micro loads program and **resets C64** (cold boot). Menu is NOT resident.

**Execution Model:**
- Standalone app **replaces menu entirely** (overwrites $080E region)
- **Fresh C64 state** (no shared memory concerns)
- Exits to menu by calling **IRQ_ExitToMenu** (requests menu reload from micro)

**Memory Constraints:**
- **NONE** - owns entire $080E-$FFFF address space (except ROM)
- Can place buffers **anywhere** (e.g., BurstLoader uses $A000)
- Full control over Zero Page (no preservation needed)

**Examples:**
- **BurstLoader** - Real-time video streaming application ($080E, buffer @ $A000)
- **WavPlayer** (legacy mode) - Audio playback application ($080E, commented out)
- **BurstLoaderTest** - Test/debug version

**Source Location:** `EasySD/Loader/Apps/` (Type B standalone applications)

**Calling Convention:**
```assembly
; Standalone app entry point:
*=$080E
AppEntry:
    SAVESTATE                    ; Save C64 state (macro)
    JSR IRQ_StartTalking         ; Initialize cartridge API
    ; ... application logic ...

    ; Exit to menu:
    JSR IRQ_ExitToMenu           ; Request menu reload from micro
    RTS                          ; C64 will be reset by micro
```

---

### 4.3 Type B Example — BurstLoader (Archived / Not Present in Current Codebase)

> **Note (2026-03-09):** BurstLoader does not exist in the current EasySD codebase. This section
> is retained as an architectural reference for the Type B pattern only.

**BurstLoader is NOT a plugin** — it is a **standalone application** (Type B).

**Source Location (archived):** `EasySD/Loader/Apps/BurstLoader/`

**Transfer Buffer:** $A000-$A18F (400 bytes)

**Rationale for $A000 (NOT an "exception"):**
- BurstLoader owns entire memory space (no menu cohabitation)
- $A000 location is a **design choice** for optimized NMI handler layout
- No conflict with plugin standards (BurstLoader is not a plugin)

**Canonical Symbol:** `BURST_BUFFER_ADDR = $A000` (defined in CartMemoryMap.inc for reference)

**Memory Map (BurstLoader):**
```
$080E - Application entry point (SAVESTATE, JSR IRQ_StartTalking)
$A000 - Transfer buffer (400 bytes, TRANSFERBUFFER = $A000)
$xxxx - NMI handlers and foreground code
```

**Documentation Header (BurstLoader.s line 1-10):**
```assembly
;----------------------------------------------------------------------------------------------------------
; BurstLoader - Real-Time Video Streaming Application
;----------------------------------------------------------------------------------------------------------
; ARCHITECTURE: Type B Standalone Application (loads at $080E, replaces menu)
;
; Memory Layout:
;   $080E: Entry point
;   $A000-$A18F: Transfer buffer (400 bytes)
;   Rationale: Optimized NMI handler layout for burst streaming (50+ handlers)
;
; Reference: docs/MEMORY_MAP_CANONICAL.md Section 4.2-4.3
;----------------------------------------------------------------------------------------------------------

TRANSFERBUFFER = $A000          ; Type B app - memory freedom
```

---

### 4.4 Category Decision Guide

**When to create Type A Plugin:**
- User wants to **browse and select files** via menu
- Program **returns to menu** after execution
- Shares memory with menu (small footprint preferred)

**When to create Type B Standalone App:**
- Program **replaces menu** entirely (exclusive control)
- Requires **full memory space** (complex, resource-intensive)
- User launches program directly (not via file selection)

**Examples:**
- File viewer/player → Type A plugin
- Full-featured video player with custom UI → Type B app
- Music player → Type A plugin (shares memory)
- Development/test tool → Type B app (clean slate)

---

## 5. Architectural Design Rationale

### 5.1 Why Zero Page Pointers for Buffer Access?

**Design Philosophy:**
- **Flexibility:** Plugins can place buffers anywhere without hardcoded constraints
- **Simplicity:** Assembler auto-placement prevents memory conflicts automatically
- **Efficiency:** Zero Page indirect indexed addressing (`LDA (ZP),Y`) is fast and compact

**Historical Context:**
The original IRQHack/EasySD design evolved from IRQ-line modulation to IO2-based protocols. Buffer addresses were never fixed in hardware - the ZP pointer approach was used from the beginning for maximum flexibility.

**Comparison:**
```assembly
; Fixed address approach (REJECTED):
LDA FIXED_BUFFER, Y     ; Requires buffer at specific address

; ZP pointer approach (ADOPTED):
LDA (ZP_PTR), Y         ; Buffer can be anywhere
```

### 5.2 Why $C000 Entry Point for Type A Plugins?

**Rationale:**
- C64 memory map: $C000-$CFFF is typically free RAM (not used by BASIC/Kernal when cartridge active)
- Cartridge ROM is at $8000-$9FFF (does not conflict)
- Page boundary alignment ($C000) simplifies addressing
- High enough to avoid menu code ($080E-$0FFF)

**Menu Loader Compatibility:**
Menu reads entry point from PRG header (first 2 bytes), then jumps via `JMP (PLUGIN_LOAD_ADDR_LO)`. While $C000 is standard, technically any address could work if specified in PRG header.

### 5.3 Why Assembler Auto-Placement is Recommended

**Benefits:**
- **Prevents conflicts:** Assembler automatically places buffers after code
- **Simplifies development:** No manual memory map management
- **Flexible:** Easy to add/remove code without recalculating buffer addresses
- **Safe:** Compile-time checks catch overflow issues

**Example:**
```assembly
*=$C000
PluginEntry:
    JMP Main

; Code auto-placed here (assembler calculates addresses)
Main:
    ; ...

; Buffer auto-placed after code (no explicit ORG needed)
MyBuffer:
    .res 416        ; Assembler places at $C670 (after code ends)
```

---

## 6. Validation and Compliance Testing

### 6.1 Type A Plugin Compliance Checklist

**Mandatory Requirements:**
- [ ] Entry point at `*=$C000` (or address specified in PRG header)
- [ ] Includes API macros: `.include "../../Loader/APIMacros.s"`
- [ ] Uses `#SETADDR` macro to pass buffer address to API (or manual ZP setting)
- [ ] Returns to menu via `RTS` (not `IRQ_ExitToMenu`)
- [ ] Does NOT overwrite menu memory ($080E-$0FFF region)

**Recommended Practices:**
- [ ] Uses assembler auto-placement for buffers (no explicit `*=` for buffers)
- [ ] Includes compile-time overflow checks (`.if * > $DF00` etc.)
- [ ] Documents buffer size requirements in header comments

### 6.2 Type B Standalone App Compliance Checklist

**Mandatory Requirements:**
- [ ] Entry point at `*=$080E`
- [ ] Calls `IRQ_StartTalking` to initialize cartridge API
- [ ] Exits to menu via `IRQ_ExitToMenu` (NOT `RTS`)

**Recommended Practices:**
- [ ] Uses `SAVESTATE` macro to preserve C64 state
- [ ] Documents architecture type in header comment
- [ ] References this document (Section 4.2) in header

### 6.3 Manual Audit Commands

**Check Type A plugins:**
```bash
# Verify entry point at $C000
grep -n "\*=\$C000" EasySD/Plugins/*/*.s

# Verify KernalBridge does NOT call IRQ_ExitToMenu (it launches programs, never returns to menu)
grep -c "IRQ_ExitToMenu" EasySD/Loader/Bridges/KernalBridge/*.s  # Should be 0
```

**Note (2026-03-09):** Type A plugins are in `EasySD/Plugins/`. KernalBridge and MultiLoad are in
`EasySD/Loader/Bridges/` and are special cases (they launch programs rather than returning to menu).
There are no active Type B standalone apps in this codebase.

**Note (2026-03-15):** MultiLoad installs a resident hook at $033C (RL_STUB, 20 bytes) and $E800
(RL_HANDLER, ~400 bytes). These regions are outside the $C000-$CFFF plugin range; see Section 3.3.

---

## 7. Integration with Other Documents

### 7.1 Cross-References

**Related Normative Documents:**
- **IO2_PROTOCOL_SPECIFICATION.md** - Streaming protocol using ZP pointer-based buffers
- **ZP_GUIDELINES.md** - Zero Page usage rules (API parameters $64-$95)
- **CartMemoryMap.inc** - High memory symbol definitions (optional reference)
- **CartZpMap.inc** - Zero Page API parameter definitions (mandatory for API use)
- **A.3.0_PLUGIN_ARCHITECTURE_RESEARCH.md** - Type A/B categorization research (Sprint A.3.0)
- **A.3.0_REFACTORING_DECISION.md** - NO-GO decision rationale (Sprint A.3.0)

**Related Informative Documents:**
- **ARCHITECTURE_REVIEW.md** - Overall architecture context
- **BurstLoader/MemUsage.txt** - BurstLoader memory layout (Type B app design spec)

### 7.2 Document Hierarchy

```
ARCHITECTURE_CONSOLIDATION_PLAN.md (Master Plan)
├── MEMORY_MAP_CANONICAL.md v2.0 (THIS DOCUMENT - normative)
│   ├── CartMemoryMap.inc (optional symbols)
│   └── CartZpMap.inc (mandatory ZP parameters)
├── IO2_PROTOCOL_SPECIFICATION.md (normative)
├── A.3.0_PLUGIN_ARCHITECTURE_RESEARCH.md (research findings)
└── A.3.0_REFACTORING_DECISION.md (NO-GO decision)
```

**Conflict Resolution:** In case of conflict, this document (v2.0) takes precedence over v1.0 and all pre-Sprint A.3.0 assumptions.

---

## 8. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-29 | Sprint A.2.1 | Initial normative specification (INCORRECT ASSUMPTIONS) |
| 2.0 | 2025-12-30 | Sprint A.3.0 | **MAJOR REVISION** - Corrected architectural assumptions based on code research:<br>- Section 1.1: Fixed buffer → ZP pointer-based architecture<br>- Section 2: Simplified compliance rules (no fixed buffer requirement)<br>- Section 4: "BurstLoader Exception" → "Program Categories (Type A/B)"<br>- Section 5: Added ZP pointer design rationale<br>- All sections: Updated to reflect actual system behavior |

### Version 2.0 Summary of Changes

**What was WRONG in v1.0:**
- ❌ Claimed all plugins MUST use $C000-$C19F for buffers (FALSE - no plugin does this)
- ❌ Treated BurstLoader as a "plugin exception" (FALSE - it's a Type B standalone app)
- ❌ Assumed fixed buffer addresses (FALSE - API uses ZP pointers)

### Version 2.2 Update (2026-03-09)

**Corrections to reflect actual codebase (EasySD v3.1.3):**
- ✅ All `IRQHack64/` paths replaced with `EasySD/` (project was renamed)
- ✅ `KernalBridge` is the correct name — was never renamed to KernalIOShim
- ✅ `KernalBridge` location: `EasySD/Loader/Bridges/KernalBridge/` (NOT `Loader/Shims/`)
- ✅ BurstLoader does NOT exist in this codebase — removed/archived. Type B section retained for architectural reference only.
- ✅ Plugin list updated: added `CvdPlayer`; build artifacts: `prgplugin.prg`, `koaplugin.prg`, `musplugin.prg`, `petgplugin.prg`, `wavplugin.prg`, `cvdplugin.prg`

**What is CORRECT in v2.0/v2.1:**
- ✅ Documents ZP pointer-based API architecture (matches actual code)
- ✅ Categorizes programs as Type A (plugins @ $C000) vs Type B (apps @ $080E)
- ✅ Recommends assembler auto-placement (matches existing plugin practices)

**Research Foundation (Sprint A, archived):**
- A.3.0_PLUGIN_ARCHITECTURE_RESEARCH.md (plugin loader analysis, buffer location mapping)
- A.3.0_REFACTORING_DECISION.md (NO-GO decision on v1.0-based refactoring)
- Compiled symbol files (koala.txt, petg.txt, mus.txt, wav.txt)
- Source code analysis (EasySDMenu.s, CartLib.s, BurstLoader.s)

---

### Version 2.3 Update (2026-03-15)

**Sprint 14 — MultiLoad plugin added:**
- ✅ Section 3.3 added: ResidentLoader memory regions (`$033C` RL_STUB, `$E800` RL_HANDLER)
- ✅ Section 4.1 Examples: added MultiLoad (`bootplugin.prg`)
- ✅ Section 6.3 audit note: added MultiLoad Bridges note
- ✅ Plugin list: `prgplugin.prg`, `koaplugin.prg`, `musplugin.prg`, `petgplugin.prg`,
  `wavplugin.prg`, `cvdplugin.prg`, **`bootplugin.prg`** (7 total)

---

**Approval Status:** v2.0 approved by user (2025-12-30)
**Effective Date:** Immediate (replaces v1.0)

---

**END OF SPECIFICATION**
