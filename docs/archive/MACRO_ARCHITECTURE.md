# Macro Architecture - EasySD

**Created:** 2025-12-27 (Macro Sprint 1)
**Status:** Active (Tier 1+2 Complete, KernalBridge adopted)
**Version:** Sprint 2+ (KernalBridge APIMacros adoption complete)

---

## Overview

The IRQHack64 macro architecture provides a **three-tier system** for code standardization, reusability, and architectural contracts in 64tass assembly.

This document describes the design principles, macro hierarchy, and usage patterns established in the macro refactoring project.

---

## Design Philosophy

### Core Principles

1. **Macros as Architectural Contracts**
   - Define what MUST be true at entry
   - Guarantee what WILL be true at exit
   - Enforce consistent patterns across components

2. **Self-Documenting Code**
   - Macro names clearly describe intent
   - Parameters are explicit and type-safe
   - Usage examples in inline documentation

3. **Zero Behavioral Change**
   - Macros expand to identical bytecode as manual patterns
   - No performance regression
   - No timing changes

4. **Few But Powerful**
   - Small set of well-designed macros
   - Each macro solves a real, frequent problem
   - Avoid macro proliferation

---

## Three-Tier Macro System

### Tier 1: Base System Macros (Sacred)

**Location:** `IRQHack64/Loader/SystemMacros.s`
**Scope:** Globally consistent, used everywhere
**Purpose:** Hardware access patterns, critical operations

**Characteristics:**
- **Non-negotiable** - Must be used when pattern applies
- **Globally enforced** - Same behavior across all code
- **Well-documented** - Comprehensive inline docs
- **Tested extensively** - Zero tolerance for bugs

**Current Macros (Sprints 1-2):**
- `READCART` - Cartridge bank read/store
- `READCART_MODULATED` - Modulated cartridge read
- `SETBANK` - Processor port configuration
- `SAVEREGS` / `RESTOREREGS` - Register preservation
- `WAITFOR` - Status polling loop
- `WAITVALUE` - Value equality wait
- `SETADDR` - 16-bit zero page pointer setup **(Sprint 2)**
- `COUNTLOOP` / `ENDLOOP` - Register-based loops **(Sprint 2)**

### Tier 2: Project Standard Macros (Sprint 2 ✅)

**Location:** `IRQHack64/Loader/APIMacros.s` ✅
**Scope:** Project-wide API conventions
**Purpose:** File operations, API patterns, standardized sequences

**Current Macros:**
- `OPENFILE` - File open wrapper (6 lines → 1 line)
- `GETFILEINFO` - FAT entry retrieval (6 lines → 1 line)
- `EXTRACTFILESIZE` - File size extraction (8 lines → 1 line)
- `CLOSEFILE` - File close wrapper
- `SETADDR` - 16-bit ZP pointer setup (4 lines → 1 line); also in SystemMacros.s (Tier 1) for early-include contexts

**First full adopter:** `Loader/Bridges/KernalBridge/KernalBridge.s` — uses all 5 macros.

**Note on SETADDR placement:** KernalBridge includes APIMacros.s before CartLibStream.s, making
SETADDR available in early code sections. When CartLibStream.s is later included (bringing in
SystemMacros.s), the duplicate SETADDR definition is silently accepted by 64tass (later definition
wins; both are identical in expansion).

**Planned Macros (Sprint 3+):**
- `PLUGIN_INIT` / `PLUGIN_EXIT` - Plugin lifecycle
- Additional API patterns as needed

### Tier 3: Convenience Macros (Optional)

**Location:** Plugin-specific files
**Scope:** Local to specific plugins or modules
**Purpose:** Readability, minor shortcuts

**Characteristics:**
- **Optional** - Can be bypassed for performance
- **Local** - Not part of architectural foundation
- **Simple** - Just syntactic sugar

---

## Include Hierarchy

### Linear Chain (No Include Guards!)

64tass does NOT support include guards. The include chain is strictly linear:

```
CartLibStream.s
  ↓
CartLibHi.s
  ↓
CartLib.s
  ↓
SystemMacros.s ← **ONLY included here!**
  ↓
CartLibCommon.s
  ↓
System.inc / IRQHack.inc
```

### Critical Rules

1. **Never include SystemMacros.s directly** in plugins
2. **Always include CartLibStream.s** in plugins (highest level)
3. **Trust the chain** - macros propagate automatically

### Example (Correct)

```assembly
; In a plugin (e.g., MusPlayer.s)
.include "../../Loader/DebugMacros.s"
.include "../../Loader/APIMacros.s"         ; Optional - for Tier 2 API macros
.include "../../Loader/CartLibStream.s"     ; Required - includes SystemMacros

; Now all macros are available:
#READCART_MODULATED $a000
#SETBANK PP_CONFIG_DEFAULT
#SETADDR BUFFER, ZP_PTR
#OPENFILE FILENAME, #31, #01
```

### Anti-Pattern (Wrong!)

```assembly
; DON'T DO THIS:
.include "../../Loader/SystemMacros.s"  ; ❌ WRONG - causes duplicate definitions
.include "../../Loader/CartLibStream.s"
```

---

## Macro Syntax Reference

### Definition

```assembly
MACRONAME .macro
    ; parameter \1, \2, etc.
    LDA #\1
    STA \2
.endm
```

### Invocation

```assembly
; Recommended style (# prefix)
#MACRONAME $34, PROCESSOR_PORT

; Alternative style (. prefix)
.MACRONAME $34, PROCESSOR_PORT
```

**Recommendation:** Use `#` prefix for visual distinction from labels.

### Named Parameters (Advanced)

```assembly
MACRONAME .macro addr=$C000, mode=1
    LDA #\mode
    STA \addr
.endm

; Invocation:
#MACRONAME addr=$D020, mode=5
```

---

## Tier 1 Macro Reference

### Hardware Access

#### READCART

**Purpose:** Cartridge bank read + immediate store

```assembly
#READCART address

; Expands to:
LDA CARTRIDGE_BANK_VALUE
STA address

; Bytes: 5 (LDA abs=3, STA abs/zp=2-3)
; Cycles: 8 (LDA=4, STA=4)
```

**Use Cases:**
- Direct cartridge data reads
- Simple byte transfers from cartridge

#### READCART_MODULATED

**Purpose:** Modulated cartridge read (timing-critical)

```assembly
#READCART_MODULATED address

; Expands to:
LDA MODULATION_ADDRESS
LDA CARTRIDGE_BANK_VALUE
STA address

; Bytes: 8 (3+3+2-3)
; Cycles: 12 (4+4+4)
```

**Use Cases:**
- NMI handlers (CvidPlayer)
- Timing-synchronized transfers
- Hardware-dependent sequences

**Frequency:** 400× in CvidPlayer/NMI.s

#### SETBANK

**Purpose:** Type-safe processor port configuration

```assembly
#SETBANK PP_CONFIG_DEFAULT  ; or other constants

; Expands to:
LDA #PP_CONFIG_DEFAULT
STA PROCESSOR_PORT

; Bytes: 4 (LDA imm=2, STA zp=2)
; Cycles: 5 (LDA=2, STA=3)
```

**Valid Constants:**
- `PP_CONFIG_ALL_RAM` ($34) - All RAM, no ROM/IO
- `PP_CONFIG_RAM_ON_ROM` ($35) - RAM + I/O
- `PP_CONFIG_RAM_ON_BASIC` ($36) - RAM + I/O + KERNAL
- `PP_CONFIG_DEFAULT` ($37) - BASIC + KERNAL + I/O (default)

**Warning:** Always restore original configuration!

---

### Register Preservation

#### SAVEREGS / RESTOREREGS

**Purpose:** IRQ-safe register preservation

```assembly
#SAVEREGS
; ... code that modifies A, X, Y ...
#RESTOREREGS

; SAVEREGS expands to:
PHA
TXA
PHA
TYA
PHA

; RESTOREREGS expands to:
PLA
TAY
PLA
TAX
PLA

; Bytes: 5 + 5 = 10
; Stack usage: +3 bytes (SAVEREGS), -3 bytes (RESTOREREGS)
```

**Use Cases:**
- IRQ handlers
- NMI handlers
- Subroutines that must preserve caller state

**Note:** Does NOT preserve flags! Use `PHP`/`PLP` if needed.

---

### Status Polling

#### WAITFOR

**Purpose:** BIT-based status polling

```assembly
#WAITFOR address, branch_instruction

; Example:
#WAITFOR CARTRIDGE_BANK_VALUE, BEQ  ; Wait until zero

; Expands to:
-
    BIT address
    branch_instruction -
```

**Common Branch Instructions:**
- `BEQ` - Wait until zero (Z=1)
- `BNE` - Wait until non-zero (Z=0)
- `BPL` - Wait until bit 7 clear (N=0)
- `BMI` - Wait until bit 7 set (N=1)
- `BVC` - Wait until bit 6 clear (V=0)
- `BVS` - Wait until bit 6 set (V=1)

**Warning:** Creates INFINITE LOOP if condition never met!

#### WAITVALUE

**Purpose:** Wait for specific value

```assembly
#WAITVALUE address, expected_value

; Example:
#WAITVALUE $D012, $FF  ; Wait for raster line $FF

; Expands to:
-
    LDA address
    CMP #expected_value
    BNE -
```

---

## Conversion Statistics

### Sprint 1 (Tier 1 - Core System)

| Pattern | Occurrences | Lines Before | Lines After | Reduction |
|---------|-------------|--------------|-------------|-----------|
| READCART_MODULATED | 400 | 1200 | 400 | 800 (66%) |
| SETBANK | 3 | 6 | 3 | 3 (50%) |
| **TOTAL** | **403** | **1206** | **403** | **803 (66%)** |

### Sprint 2 (Tier 1+2 - Memory & API)

| Pattern | Identified | Converted | Location | Reduction |
|---------|-----------|-----------|----------|-----------|
| SETADDR | 20 | 4 | PrgPlugin.s | ~8 lines |
| OPENFILE | 12 | 1 | PrgPlugin.s | ~5 lines |
| GETFILEINFO | 8 | 2 | PrgPlugin.s | ~10 lines |
| EXTRACTFILESIZE | 8 | 2 | PrgPlugin.s | ~14 lines |
| CLOSEFILE | 17 | 3 | PrgPlugin.s | ~0 lines (wrapper) |
| **TOTAL** | **145+** | **12** | PrgPlugin.s | **~40 lines** |

**Potential Remaining:** ~133 patterns across 5 plugins + menu system

---

## Future Roadmap

### Sprint 2: Memory & API Macros ✅ COMPLETE

**Delivered:**
- SystemMacros.s extended (+109 lines): `SETADDR`, `COUNTLOOP`, `ENDLOOP`
- APIMacros.s created (+240 lines): `OPENFILE`, `GETFILEINFO`, `EXTRACTFILESIZE`, `CLOSEFILE`
- PrgPlugin.s refactored (12 patterns, ~40 lines saved)
- Analysis tools created (145+ patterns identified)

### Sprint 3: Plugin Standardization

**Goals:**
- Refactor all 6 plugins with macro patterns
- Create `PLUGIN_INIT` / `PLUGIN_EXIT` macros
- Standardize error handling

### Sprint 4: Integration & Optimization

**Goals:**
- Performance profiling
- Critical path optimization
- Binary size analysis

### Sprint 5: Documentation & Knowledge Transfer

**Goals:**
- Complete macro reference guide
- Migration guide for new code
- Template plugin with all macros

---

## Best Practices

### DO:
- ✅ Use `#` prefix for macro invocations
- ✅ Check macro documentation before use
- ✅ Trust the include chain (use CartLibStream.s)
- ✅ Use macros consistently when pattern applies
- ✅ Report bugs or issues with macro behavior

### DON'T:
- ❌ Include SystemMacros.s directly in plugins
- ❌ Create duplicate macros with same name
- ❌ Bypass macros for "optimization" without profiling
- ❌ Use macros for dynamic/computed patterns (use subroutines)
- ❌ Modify macro definitions without architectural review

---

## Resources

**Documentation:**
- `docs/archive/sprints/MACRO_REFACTORING_MASTER_PLAN.md` - 5-sprint roadmap
- `docs/archive/sprints/SPRINT1_MACRO_COMPLETION.md` - Sprint 1 report (Tier 1 macros)
- `docs/archive/sprints/SPRINT2_MACRO_COMPLETION.md` - Sprint 2 report (Tier 1+2 extensions)
- `IRQHack64/Loader/SystemMacros.s` - Tier 1 macro source with inline docs
- `IRQHack64/Loader/APIMacros.s` - Tier 2 API macro source with inline docs

**External References:**
- [64tass Official Manual](https://tass64.sourceforge.net/)
- [64tass Learn-by-Example](https://www.sheep-thrills.net/64tass_learn-by-example.html)

---

**Last Updated:** 2025-12-28 (Macro Sprint 2)
**Status:** Active - Tier 1+2 Complete, Ready for Plugin Conversion (Sprint 3)
