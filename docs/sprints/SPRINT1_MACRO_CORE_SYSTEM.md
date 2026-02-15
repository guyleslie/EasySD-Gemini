# Sprint 1: Core System Macros

**Sprint Goal:** Establish foundational architectural macros for IRQHack64
**Duration:** Sprint 1 of 5
**Started:** 2025-12-27
**Status:** IN PROGRESS

---

## Objectives

Create the **Tier 1 Base System Macros** that form the sacred, globally-consistent foundation of the macro architecture. These macros will:

1. Replace the most frequent repetitive patterns (422+ occurrences)
2. Establish architectural contracts for hardware access
3. Provide type-safe, documented interfaces to critical operations

---

## Deliverables

### 1. Create `Loader/SystemMacros.s`

New file containing foundational macros:

#### READCART - Cartridge Bank Read/Store
**Frequency:** 422 occurrences
**Contract:** Single-instruction cartridge data read with immediate store

```assembly
;-----------------------------------------------
; READCART - Read from cartridge bank and store
;-----------------------------------------------
; Reads byte from cartridge bank and stores to memory
;
; Parameters:
;   \1 = Target address (absolute or zero page)
;
; Registers affected: A
; Flags affected: N, Z
;
; Example:
;   READCART $02     ; Store to zero page $02
;   READCART $C000   ; Store to absolute address
;-----------------------------------------------
READCART .macro
    LDA CARTRIDGE_BANK_VALUE
    STA \1
.endm
```

#### READCART_MODULATED - Modulated Cartridge Read
**Frequency:** 411 occurrences
**Contract:** Modulation-aware cartridge read (required for certain hardware states)

```assembly
;-----------------------------------------------
; READCART_MODULATED - Modulated cartridge read
;-----------------------------------------------
; Performs modulated cartridge read sequence
; Used in timing-critical or hardware-synchronized contexts
;
; Parameters:
;   \1 = Target address
;
; Registers affected: A
; Flags affected: N, Z
;
; Example:
;   READCART_MODULATED $02
;-----------------------------------------------
READCART_MODULATED .macro
    LDA MODULATION_ADDRESS
    LDA CARTRIDGE_BANK_VALUE
    STA \1
.endm
```

#### SETBANK - Processor Port Configuration
**Frequency:** 28 occurrences
**Contract:** Safe memory banking configuration

```assembly
;-----------------------------------------------
; SETBANK - Set processor port memory configuration
;-----------------------------------------------
; Configures C64 memory banking via processor port
;
; Parameters:
;   \1 = Configuration value:
;        PP_CONFIG_ALL_RAM      ($34) - All RAM
;        PP_CONFIG_RAM_ON_ROM   ($35) - RAM + I/O
;        PP_CONFIG_RAM_ON_BASIC ($36) - RAM + I/O + KERNAL
;        PP_CONFIG_DEFAULT      ($37) - BASIC + KERNAL + I/O
;
; Registers affected: A
; Flags affected: N, Z
;
; Example:
;   SETBANK PP_CONFIG_ALL_RAM
;-----------------------------------------------
SETBANK .macro
    LDA #\1
    STA PROCESSOR_PORT
.endm
```

#### SAVEREGS / RESTOREREGS - Register Preservation
**Frequency:** 304 occurrences (152 pairs)
**Contract:** Complete register state preservation for IRQ/subroutines

```assembly
;-----------------------------------------------
; SAVEREGS - Save all CPU registers to stack
;-----------------------------------------------
; Preserves A, X, Y registers in proper order
; Must be paired with RESTOREREGS
;
; Stack usage: 3 bytes
; Registers affected: None (all preserved)
;
; Example:
;   SAVEREGS
;   ; ... your code ...
;   RESTOREREGS
;-----------------------------------------------
SAVEREGS .macro
    PHA
    TXA
    PHA
    TYA
    PHA
.endm

;-----------------------------------------------
; RESTOREREGS - Restore all CPU registers from stack
;-----------------------------------------------
; Restores A, X, Y registers in proper order
; Must be paired with SAVEREGS
;
; Stack usage: -3 bytes (pops what SAVEREGS pushed)
; Registers affected: A, X, Y (restored to saved values)
;
; Example:
;   SAVEREGS
;   ; ... your code ...
;   RESTOREREGS
;-----------------------------------------------
RESTOREREGS .macro
    PLA
    TAY
    PLA
    TAX
    PLA
.endm
```

#### WAITFOR - Status Polling Loop
**Frequency:** 87 occurrences
**Contract:** BIT-based status register polling with branch

```assembly
;-----------------------------------------------
; WAITFOR - Wait for status bit condition
;-----------------------------------------------
; Polls memory location until bit condition met
;
; Parameters:
;   \1 = Address to poll
;   \2 = Branch instruction (BEQ, BNE, BPL, BMI, BVC, BVS)
;
; Registers affected: A (loaded from address)
; Flags affected: N, Z, V (from BIT instruction)
;
; Example:
;   WAITFOR CARTRIDGE_BANK_VALUE, BEQ  ; Wait until zero
;   WAITFOR $D012, BNE                 ; Wait until not equal
;
; Note: Uses BIT instruction for non-destructive flag testing
;-----------------------------------------------
WAITFOR .macro
-
    BIT \1
    \2 -
.endm
```

### 2. Integration Plan

#### Phase 1: Loader Core (CartLib.s, CartLibHi.s)
- [ ] Update `CartLib.s` - READCART pattern (42 occurrences)
- [ ] Update `CartLibHi.s` - SETBANK pattern (8 occurrences)
- [ ] Update `CartLibCommon.s` - WAITFOR pattern (15 occurrences)
- [ ] Test build: `build_core.bat`

#### Phase 2: Debug Variants
- [ ] Update `CartLibDebug.s` - All applicable patterns
- [ ] Update `CartLibDE.s` - Banking macros
- [ ] Update `CartLibHiDE.s` - Banking macros
- [ ] Update `CartLibCommonDE.s` - Polling macros
- [ ] Test build: `Build - EasySD - DEBUG.bat`

#### Phase 3: High-Frequency Plugin (BurstLoader)
- [ ] Update `Plugins/BurstLoader/NMI.s` - READCART_MODULATED (411 occurrences!)
- [ ] Update `Plugins/BurstLoader/MyCartLibHi.s` - READCART patterns
- [ ] Test build: `Plugins\BurstLoader\compile.bat`

### 3. Documentation

Create macro reference section:
- [ ] `docs/MACRO_REFERENCE_TIER1.md` - Tier 1 macro documentation
- [ ] Add usage examples for each macro
- [ ] Document architectural contracts
- [ ] Migration guide snippets

---

## Implementation Strategy

### Incremental Conversion
1. **One file at a time** - Complete each file before moving to next
2. **Build after each file** - Ensure no regressions
3. **Test critical paths** - Verify loader boots, plugins load

### Macro Invocation Style
- Use `#` prefix for clarity: `#READCART $02`
- Alternative `.` prefix also valid: `.READCART $02`
- **Recommendation:** Stick with `#` for visual distinction from labels

### Include Strategy
Add to each file that needs macros:
```assembly
.include "../../Loader/SystemMacros.s"
```

Or for loader files:
```assembly
.include "SystemMacros.s"
```

---

## Testing Checklist

### Build Tests
- [ ] `build_core.bat` - Core loader builds
- [ ] `build_plugins.bat` - All plugins build
- [ ] `Build - EasySD.bat` - Full release build
- [ ] `Build - EasySD - DEBUG.bat` - Debug build

### Functional Tests
- [ ] Loader boots to menu
- [ ] Menu navigation works
- [ ] Plugin loading works
- [ ] Cartridge communication verified

### Regression Tests
- [ ] Binary size comparison (acceptable: +/- 5%)
- [ ] Performance check (boot time, load time)
- [ ] No new build warnings/errors

---

## Success Criteria

### Quantitative
- [ ] `SystemMacros.s` created with all 5 macro families
- [ ] Minimum 100 pattern occurrences converted
- [ ] All builds pass without errors
- [ ] Code reduction: ~200+ lines removed

### Qualitative
- [ ] Macros follow 64tass best practices
- [ ] Documentation is clear and complete
- [ ] Code is more readable than before
- [ ] Architectural contracts established

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Build breaks during conversion | Convert one file at a time, test immediately |
| Macro parameter confusion | Clear documentation, consistent naming |
| Performance regression | Profile critical paths, optimize if needed |
| Incomplete pattern coverage | Review diff after each conversion |

---

## Timeline

**Target Completion:** End of Sprint 1
**Estimated Effort:** 4-6 hours

### Milestones
- [x] Research and analysis complete
- [ ] SystemMacros.s created ← **CURRENT**
- [ ] CartLib family converted
- [ ] BurstLoader/NMI.s converted
- [ ] All builds passing
- [ ] Documentation complete

---

## Notes

### 64tass Macro Syntax Reference
```assembly
; Definition
MACRONAME .macro
    ; parameter \1, \2, etc.
    ; code
.endm

; Invocation
#MACRONAME arg1, arg2
.MACRONAME arg1, arg2

; Named parameters (advanced)
MACRONAME .macro addr=$C000, mode=1
    LDA #\mode
    STA \addr
.endm
```

### Conversion Example

**Before:**
```assembly
    LDA CARTRIDGE_BANK_VALUE
    STA $02
    LDA CARTRIDGE_BANK_VALUE
    STA $03
    LDA CARTRIDGE_BANK_VALUE
    STA $04
```

**After:**
```assembly
    #READCART $02
    #READCART $03
    #READCART $04
```

**Savings:** 6 lines → 3 lines (50% reduction)

---

**Next Sprint:** Sprint 2 - Memory & API Macros
**Status:** Ready to implement
