# A.3.0 Plugin Architecture Research Findings

**Created:** 2025-12-29
**Sprint:** A.3.0 (Pre-Refactoring Research Phase)
**Status:** CRITICAL DISCOVERY - Architecture Categorization Complete

---

## Executive Summary

**CRITICAL FINDING:** The IRQHack64 "Plugins" directory contains TWO distinct categories of programs with fundamentally different architectures:

1. **Type A: True Plugins** ($C000+) - Loaded by menu, return to menu
2. **Type B: Standalone Applications** ($080E) - Replace menu, use cartridge API

**BurstLoader is NOT a plugin** - it is a **standalone video player application** that replaces the menu when launched.

---

## 1. Plugin Loader Mechanism Analysis

### 1.1 Menu Loader Code (IrqLoaderMenuNew.s)

**Location:** `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s`

**Entry Point:** Line 62 - `*=$080E` (C64 BASIC program start address)

**Plugin Loading Logic (lines 432-570):**

#### BIN Plugin Loading (lines 455-558)
```assembly
BINPLUGINEXISTS
    ; Read first 256 bytes to PLUGIN_HEADER to get PRG load address
    #SETADDR PLUGIN_HEADER, ZP_IRQ_API_DATA_LO
    LDA #1                          ; Read 1 page (256 bytes)
    STA ZP_IRQ_API_DATA_LENGTH
    JSR IRQ_ReadFileNoCallback

    ; Parse PRG load address (first 2 bytes)
    LDA PLUGIN_HEADER               ; Low byte
    STA PLUGIN_LOAD_ADDR_LO
    STA ZP_IRQ_API_DATA_LO          ; Target load address
    LDA PLUGIN_HEADER+1             ; High byte
    STA PLUGIN_LOAD_ADDR_HI
    STA ZP_IRQ_API_DATA_HI

    ; Get file size and load full payload
    #GETFILEINFO PLUGIN_HEADER
    #EXTRACTFILESIZE PLUGIN_HEADER, ZP_LOADFILE_API_SIZE0
    JSR LoadFileBySize

    ; **CRITICAL LINE 558:**
    JMP (PLUGIN_LOAD_ADDR_LO)       ; Indirect jump to plugin entry point
```

**KEY INSIGHT:** The menu does NOT assume $C000 as entry point! It reads the PRG header (first 2 bytes) and jumps to whatever address the plugin specifies.

#### PRG Plugin Loading (lines 561-570)
```assembly
PRGPLUGINEXISTS
    JSR IRQ_CloseFile
    JSR PrepareFileNameParameter
    JSR IRQ_InvokeWithName          ; Micro loads PRG and resets C64
    JMP *                           ; Infinite loop (execution never returns)
```

---

## 2. Architecture Categorization

### 2.1 Type A: True Plugins ($C000+)

**Load Address:** $C000 (or higher, as specified in PRG header)

**Loading Method:** Menu loads plugin into memory, then executes `JMP (PLUGIN_LOAD_ADDR_LO)`

**Execution Model:**
- Plugin runs in same C64 session as menu
- Shares Zero Page with menu (must preserve ZP state)
- Returns to menu when done

**Examples:**
- **PrgPlugin** - PRG file loader ($C000)
- **KoalaDisplayer** - Koala image viewer ($C000)
- **PetsciiDisplayer** - PETSCII art viewer ($C000)

**Memory Layout:**
```
$080E - $xxxx : Menu code (still resident in memory)
$C000 - $xxxx : Plugin code and data
```

**Calling Convention:**
```assembly
; Menu side:
JMP (PLUGIN_LOAD_ADDR_LO)       ; Jump to plugin

; Plugin side:
PluginEntry:
    ; ... plugin logic ...
    RTS                          ; Return to menu
```

---

### 2.2 Type B: Standalone Applications ($080E)

**Load Address:** $080E (C64 BASIC program start address)

**Loading Method:** Arduino/micro loads program and resets C64 (cold boot)

**Execution Model:**
- **Replaces menu entirely** (overwrites $080E region)
- Fresh C64 state (no shared ZP concerns)
- Exits to menu by requesting reload via `IRQ_ExitToMenu`

**Examples:**
- **BurstLoader** - Real-time video streaming application ($080E)
- **WavPlayer** - Audio playback application ($080E)
- **BurstLoaderTest** - Test/debug version ($080E)

**Memory Layout:**
```
$080E - $xxxx : Standalone app code and data (menu is NOT resident)
$A000 - $xxxx : BurstLoader transfer buffer (EXCEPTION)
```

**Calling Convention:**
```assembly
; Standalone app entry point:
*=$080E
    SAVESTATE                    ; Save C64 state
    JSR IRQ_StartTalking         ; Initialize cartridge API
    ; ... application logic ...

    ; Exit to menu:
    JSR IRQ_ExitToMenu           ; Request menu reload from micro
    RTS                          ; C64 will be reset by micro
```

---

## 3. BurstLoader Architecture Deep Dive

### 3.1 Why BurstLoader is NOT a Plugin

**Evidence from BurstLoader.s:**

**Line 24:**
```assembly
*=$080E                 ; ← SAME address as menu!
```

**Line 15:**
```assembly
TRANSFERBUFFER = $A000  ; ← Transfer buffer at $A000 (NOT $C000)
```

**Lines 26-30:**
```assembly
SAVESTATE               ; Save C64 state (macro)
JSR IRQ_DisableDisplay
JSR INIT
JSR IRQ_StartTalking    ; Initialize cartridge communication
```

**Line 121:**
```assembly
JSR IRQ_ExitToMenu      ; Return to menu (triggers micro reload)
```

### 3.2 BurstLoader's $A000 Transfer Buffer Justification

**Original Plan Assumption (INCORRECT):**
> "BurstLoader is a plugin that deviates from standard $C000 buffer for performance reasons."

**CORRECT Understanding:**
> "BurstLoader is a **standalone application** (not a plugin) that loads at $080E. It uses $A000 for its transfer buffer because:
> 1. It owns the entire memory space (no menu cohabitation)
> 2. Optimized NMI handler layout requires specific memory organization
> 3. $C000 region may be used for other purposes (screen memory, code, etc.)"

**MemUsage.txt Reinterpretation:**
- Document is a **design specification** showing standard plugin layout
- BurstLoader does NOT follow this layout because **it's not a plugin**
- No "exception" needed - different program category entirely

---

## 4. Memory Map Implications

### 4.1 Type A Plugins (True Plugins) Memory Requirements

**MUST comply with:**
- Entry point at address specified in PRG header (typically $C000)
- Transfer buffer at `TRANSFER_BUFFER_ADDR` ($C000-$C19F) **IF** using standard API
- NMI handlers at `NMI_HANDLER_REGION_START` ($C1A0+) if needed
- **MUST NOT corrupt menu's memory regions**

**Rationale:** Plugin shares memory with menu (menu remains resident).

### 4.2 Type B Standalone Apps Memory Freedom

**NO memory map constraints:**
- Can use $080E-$FFFF freely (except ROM regions)
- Can define transfer buffers anywhere (e.g., BurstLoader @ $A000)
- Full control over Zero Page (no sharing with menu)
- Only constraint: Must use cartridge API for file I/O

**Rationale:** Standalone app owns entire memory space.

---

## 5. Refactoring Strategy Impact

### 5.1 Original Plan (v2.0) - INCORRECT Assumptions

**Assumption:**
> "All plugins use $C000 for buffers, some have hardcoded addresses that need to be replaced with canonical symbols."

**Reality:**
- Type A plugins (PrgPlugin, KoalaDisplayer) load at $C000 but use **assembler auto-placement** for buffers
- Type B apps (BurstLoader, WavPlayer) load at $080E and have **no memory map constraints**

### 5.2 Revised Refactoring Strategy

#### For Type A Plugins (True Plugins):
**Goal:** Add explicit `*=TRANSFER_BUFFER_ADDR` directives for clarity and compliance.

**Rationale:**
- Ensures plugins explicitly reserve standard buffer region
- Prevents accidental conflicts with menu memory
- Documents architectural compliance

**Example (PrgPlugin.s):**
```assembly
.include "../../Loader/CartMemoryMap.inc"

*=$C000
PluginEntry:
    JMP Main

; Explicit buffer placement (was auto-placed at $D032)
*=TRANSFER_BUFFER_ADDR              ; $C000
FileInfoBuffer:
    .res TRANSFER_BUFFER_SIZE

*=$C700
Main:
    ; ... plugin logic ...
    RTS
```

#### For Type B Standalone Apps (BurstLoader, WavPlayer):
**Goal:** Document architectural category, NO refactoring required.

**Rationale:**
- Standalone apps have NO memory map constraints
- $A000 buffer (BurstLoader) is a **design choice**, not an exception
- Refactoring would provide NO architectural value

**Action:**
- Add header comment explaining standalone app category
- Reference this document (A.3.0_PLUGIN_ARCHITECTURE_RESEARCH.md)

**Example (BurstLoader.s header):**
```assembly
;----------------------------------------------------------------------------------------------------------
; BurstLoader - Real-Time Video Streaming Application
;----------------------------------------------------------------------------------------------------------
; ARCHITECTURE: Type B Standalone Application (loads at $080E, replaces menu)
;
; This is NOT a plugin. It is a standalone application that uses the cartridge API library.
; Memory layout is NOT constrained by plugin standards (no menu cohabitation).
;
; Transfer Buffer: $A000-$A18F (400 bytes)
; Rationale: Optimized NMI handler requires specific memory layout for burst streaming.
;
; Reference: docs/sprints/A.3.0_PLUGIN_ARCHITECTURE_RESEARCH.md Section 3
;----------------------------------------------------------------------------------------------------------
```

---

## 6. Canonical Memory Map Document Updates Required

### 6.1 MEMORY_MAP_CANONICAL.md Section 4 (Special Cases) - REWRITE NEEDED

**Current Section 4.1 (INCORRECT):**
> "BurstLoader Plugin Exception"

**Should be:**
> "Standalone Applications (Type B Programs)"

**Proposed New Section 4:**

```markdown
## 4. Standalone Applications (Type B Programs)

### 4.1 Definition and Scope

**Standalone applications** are programs that load at $080E (BASIC start address) and **replace the menu** when executed. They are NOT plugins and do NOT share memory with the menu.

**Examples:**
- BurstLoader (real-time video streaming)
- WavPlayer (audio playback)

### 4.2 Memory Map Exemption

**Standalone applications are EXEMPT from plugin memory map standards.**

**Rationale:**
- Load address $080E (not $C000)
- Replace menu entirely (no cohabitation)
- Fresh C64 state (no ZP sharing concerns)
- Own entire memory space $080E-$FFFF

### 4.3 BurstLoader Transfer Buffer ($A000-$A18F)

**Address:** $A000-$A18F (400 bytes)

**Purpose:** Transfer buffer for burst video streaming

**Why NOT $C000:**
BurstLoader is a standalone application with full memory freedom. The $A000 location is a **design choice** for optimized NMI handler layout, NOT an "exception" to plugin standards.

**Reference Implementation:**
See BurstLoader.s line 15: `TRANSFERBUFFER = $A000`

### 4.4 Documentation Requirements for Type B Apps

1. Header comment identifying program as "Type B Standalone Application"
2. Reference to this architecture research document
3. Rationale for any non-standard memory layout choices
```

---

## 7. Plugin Calling Convention

### 7.1 Type A Plugin Calling Convention

**Entry:**
```assembly
; Menu side (IrqLoaderMenuNew.s line 558):
JMP (PLUGIN_LOAD_ADDR_LO)           ; Indirect jump to plugin entry point
```

**Exit:**
```assembly
; Plugin side:
PluginMain:
    ; ... plugin logic ...
    RTS                              ; Return to menu
```

**Zero Page State:**
- Plugin MUST preserve all ZP variables used by menu
- Temporary ZP usage allowed, but MUST restore on exit
- API parameters ($90-$95, $64-$74) are volatile

**Memory State:**
- Menu code remains resident at $080E+
- Plugin MUST NOT overwrite menu memory
- Plugin can use $C000+ freely (above menu code)

### 7.2 Type B Standalone App Calling Convention

**Entry:**
```assembly
*=$080E
AppEntry:
    SAVESTATE                        ; Save C64 state (macro)
    ; ... application initialization ...
```

**Exit:**
```assembly
; Application side:
ExitToMenu:
    JSR IRQ_ExitToMenu               ; Request menu reload
    RTS                              ; C64 will be reset by micro
```

**Zero Page State:**
- Full ZP ownership (no preservation required)
- Fresh C64 state on load

**Memory State:**
- Owns entire $080E-$FFFF (except ROM)
- No menu cohabitation concerns

---

## 8. Next Steps for A.3.0 Research

### 8.1 Completed Tasks
- ✅ Analyzed menu loader mechanism (IrqLoaderMenuNew.s)
- ✅ Categorized all programs (Type A vs Type B)
- ✅ Understood BurstLoader's true architectural role
- ✅ Documented calling conventions

### 8.2 Remaining A.3.0 Tasks
- [ ] Compile all Type A plugins to get symbol files
- [ ] Map actual buffer locations for Type A plugins
- [ ] Create Go/No-Go decision document for refactoring
- [ ] Update MEMORY_MAP_CANONICAL.md Section 4
- [ ] Update ARCHITECTURE_CONSOLIDATION_PLAN.md with new categorization

---

## 9. Recommendations

### 9.1 Immediate Actions
1. **Update MEMORY_MAP_CANONICAL.md** - Rewrite Section 4 to reflect Type A/B categorization
2. **Rename "Plugin Exception"** - BurstLoader is NOT an exception, it's a different category
3. **Create Architecture Diagram** - Visual representation of Type A vs Type B

### 9.2 Refactoring Scope Reduction
**ONLY Type A plugins require refactoring:**
- PrgPlugin
- KoalaDisplayer
- PetsciiDisplayer
- MusPlayer (if Type A)

**Type B apps require DOCUMENTATION ONLY:**
- BurstLoader (add header comment)
- WavPlayer (add header comment, determine if dual-mode)

### 9.3 Documentation Improvements
- Update all "plugin" references to distinguish Type A/B
- Create glossary: "Plugin" = Type A, "Standalone App" = Type B
- Add architecture decision record (ADR) explaining categorization

---

**END OF RESEARCH FINDINGS**
