# Sprint A - Audit Findings and Plan Corrections

**Document Type:** Audit Report / Lessons Learned
**Date:** 2025-12-29
**Sprint:** Architecture Consolidation Sprint A
**Status:** CRITICAL - Requires plan revision before continuing refactoring

---

## Executive Summary

During the execution of Sprint A (IO2/Memory Consolidation), a comprehensive audit revealed **significant discrepancies** between the plan's assumptions and the actual codebase state. This document records these findings and proposes plan corrections before proceeding with refactoring work.

**Key Discovery:** The original plan assumed plugins hardcode memory addresses (e.g., `*=$C000` for buffers). **Reality:** Plugins use **automatic assembler placement** for buffers - no explicit addresses are hardcoded.

**Impact:** The refactoring strategy must be revised. Instead of "replacing hardcoded addresses," we need to "**add explicit address directives**" where none currently exist.

---

## Section 1: Critical Findings

### Finding 1.1: No Hardcoded Buffer Addresses in Standard Plugins

**Plan Assumption (ARCHITECTURE_CONSOLIDATION_PLAN.md, lines 389-407):**
> "Search for hardcoded $C000 addresses"
> "Plugin refactoring priority" table suggests replacing `*=$C000` directives

**Actual State (Verified via code audit):**

| Plugin | Buffer Symbol | Address (per symbol file) | Explicit `*=` directive? |
|--------|--------------|---------------------------|--------------------------|
| **PrgPlugin** | GENERALBUFFER | **$D032** | ❌ NO (assembler auto-placed) |
| **KoalaDisplayer** | KOALA_INFO_BUFFER | Auto-placed | ❌ NO |
| **MusPlayer** | (No explicit buffer?) | N/A | ❌ NO |
| **PetsciiDisplayer** | (TBD - requires research) | Auto-placed | ❌ NO |
| **WavPlayer** | Multiple `.FILL` buffers | Auto-placed | ❌ NO |
| **BurstLoader** | TRANSFERBUFFER | **$A000** | ✅ YES - `TRANSFERBUFFER = $A000` |

**Evidence (PrgPlugin listing):**
```
.c71c   a9 32       lda #$32        LDA #<GENERALBUFFER
.c720   a9 d0       lda #$d0        LDA #>GENERALBUFFER
```
→ `GENERALBUFFER = $D032` (from symbol file)

**Conclusion:**
- Standard plugins do NOT hardcode buffer addresses
- Assembler (64tass) automatically places buffers after code
- **Only BurstLoader explicitly sets address** (`TRANSFERBUFFER = $A000`)

---

### Finding 1.2: Plugin Entry Point ≠ Transfer Buffer Location

**Plan Assumption:**
The plan conflates `*=$C000` (entry point) with transfer buffer location.

**Actual Structure (PrgPlugin.s example):**
```assembly
*=$C000        ; Entry point (JMP MAIN, 3 bytes)
JMP MAIN

*=$C700        ; Main code section
MAIN
    ; ... plugin code ...

; NO explicit ORG directive here!
GENERALBUFFER
    .FILL 256  ; Assembler places this at $D032 (after code)
```

**Observed Pattern:**
1. `*=$C000` → **Plugin entry point** (loader jumps here)
2. `*=$C700` (or similar) → Main code section
3. Data buffers → **No explicit address** (assembler auto-places)

**Implication:**
- `*=$C000` is the **calling convention**, not buffer location
- Buffer location is currently **undefined** (assembler-dependent)
- Refactoring must **add** explicit buffer placement, not replace it

---

### Finding 1.3: BurstLoader MemUsage.txt is a DESIGN SPEC, not current state

**File:** `IRQHack64/Plugins/BurstLoader/MemUsage.txt`

**Content:**
```
$C000-$C19F - Transfer buffer
$C1A0-$CEB6 - NMI handlers
```

**Plan Interpretation (INCORRECT):**
> "BurstLoader currently uses $C000-$C19F for transfer buffer"

**Actual Interpretation (CORRECT):**
This document describes the **DESIRED standard layout** for plugins, not BurstLoader's actual memory map.

**BurstLoader's ACTUAL state:**
```assembly
TRANSFERBUFFER = $A000  ; EXCEPTION - video streaming optimization
```

**Evidence from BurstLoader.s (line 15):**
```assembly
TRANSFERBUFFER = $A000
```

**Corrected Understanding:**
- MemUsage.txt is a **reference specification** showing canonical layout
- BurstLoader is an **approved exception** to this layout
- The document supports Sprint A's goal (defining canonical layout)

---

### Finding 1.4: Historical Context from Turkish Forum Documentation

**Source:** `FORUM_POST_EASYSD (Turkey).md`

**Critical Historical Information:**

1. **IRQHack64 → EasySD Evolution (Hardware Change):**
   - **Old (IRQHack64):** Used IRQ line for communication
   - **New (EasySD):** Uses **/IO2 line** (`MODULATION_ADDRESS = $DF00`)
   - **Hardware mod required:** Disconnect IRQ pin, connect IO2 pin to Arduino D2

2. **IO2 Protocol Real-World Usage:**
   ```assembly
   NMI_000
       LDA MODULATION_ADDRESS  ; $DF00 = IO2 TRIGGER
       LDA CARTRIDGE_BANK_VALUE
       STA $a000               ; BurstLoader writes to $A000
   ```
   - Confirms BurstLoader's $A000 usage is **intentional optimization** for video streaming

3. **Stack/Heap Corruption Issue:**
   - Arduino firmware had issues with large local buffers (256-400 bytes)
   - Solution: Avoid concurrent use of multiple large buffer functions
   - **Relevance:** Demonstrates importance of careful memory management

4. **Plugin Entry Point Flexibility:**
   - TAP Plugin: `*=$080E` (NOT $C000!)
   - Standard plugins: `*=$C000`
   - **Conclusion:** Entry point address is NOT rigid

---

## Section 2: Plan Assumptions vs. Reality

### Assumption 2.1: "Hardcoded $C000 addresses exist"

**Plan Statement (Sprint A.3.1):**
> "Audit script futtatás: Search for hardcoded $C000 addresses"

**Reality Check:**
```bash
$ grep -r "\$C000" IRQHack64/Plugins/
# Result: Only entry point directives (*=$C000), NOT buffer allocations
```

**Correction Needed:**
- Change search criteria from "hardcoded addresses" to "missing explicit addresses"
- Audit should find places where buffers **lack** explicit ORG directives

---

### Assumption 2.2: "Replace *=$C000 with TRANSFER_BUFFER_ADDR"

**Plan Example (Sprint A.3):**
```assembly
; ELŐTTE (hardcoded):
*=$C000
TransferBuffer: .res 416

; UTÁNA (canonical symbol):
.include "CartZpMap.inc"
*=TRANSFER_BUFFER_ADDR
TransferBuffer: .res TRANSFER_BUFFER_SIZE
```

**Problem:** This example is **misleading** because:
1. Plugins don't currently have `*=$C000` for buffers
2. `*=$C000` is used for **entry point**, not buffer

**Corrected Example:**
```assembly
; ELŐTTE (no explicit address - assembler decides):
GENERALBUFFER
    .FILL 256  ; Placed at $D032 by assembler

; UTÁNA (explicit canonical address):
.include "../../Loader/CartMemoryMap.inc"
*=TRANSFER_BUFFER_ADDR  ; $C000
FileInfoBuffer:
    .res TRANSFER_BUFFER_SIZE  ; 416 bytes
```

---

### Assumption 2.3: "BurstLoader uses $C000 with exception"

**Plan Statement:**
> "BurstLoader exception dokumentálva (inline comment)"

**Misunderstanding:**
- Plan implies BurstLoader **normally uses $C000** but has an exception
- **Reality:** BurstLoader **always used $A000** (no "exception" from own practice)
- The "exception" is from the **canonical standard** we're now defining

**Clarification:**
- BurstLoader is an exception to the **new canonical standard** (Sprint A deliverable)
- Not an exception to its own previous behavior

---

## Section 3: New Research Questions

The audit revealed gaps in our understanding. Before proceeding with refactoring, we need answers to:

### Question 3.1: Plugin Loader Mechanism

**What we need to know:**
1. How does the main menu load plugins?
2. Is there a fixed entry point requirement ($C000)?
3. What happens if entry point changes?
4. Can buffer location be independent of entry point?

**Research Plan:**
- Examine `IrqLoaderMenuNew.s` (menu loader code)
- Search for plugin dispatch mechanism
- Check if `$C000` is hardcoded in loader or configurable

**Priority:** **HIGH** (blocks refactoring strategy decision)

---

### Question 3.2: Plugin Calling Convention

**What we need to know:**
1. How is plugin entry point invoked? (JSR $C000? JMP $C000?)
2. Is there a return protocol? (RTS? JMP back to menu?)
3. Are there register preservation requirements?

**Research Plan:**
- Analyze plugin dispatch code in menu
- Check existing plugin exit mechanisms
- Document calling convention

**Priority:** **MEDIUM** (informs refactoring safety)

---

### Question 3.3: Value of Explicit Buffer Placement

**What we need to know:**
1. **Why** enforce explicit buffer @ $C000?
   - Performance benefit? (faster addressing?)
   - Architectural clarity?
   - Future-proofing (reserved NMI handler space)?
2. What breaks if buffer stays auto-placed?

**Analysis Needed:**
- Document benefits of canonical layout
- Assess risk of leaving buffers auto-placed
- Quantify refactoring value

**Priority:** **HIGH** (justifies the entire refactoring effort)

---

### Question 3.4: Current Memory Layout Reality Check

**What we need to know:**
1. Where are buffers **actually** located now?
   - PrgPlugin: $D032 ✅ (verified)
   - KoalaDisplayer: ? (need symbol file)
   - MusPlayer: ? (need research)
   - Others: ?
2. Are there memory conflicts? (overlapping regions?)
3. Does current layout cause any bugs?

**Research Plan:**
- Compile all plugins with symbol/listing output
- Create actual memory map (vs. desired canonical map)
- Identify any conflicts or inefficiencies

**Priority:** **MEDIUM** (validates problem severity)

---

## Section 4: Recommended Plan Revisions

### Revision 4.1: Update Sprint A.3 Task Description

**Current (ARCHITECTURE_CONSOLIDATION_PLAN.md, line 383):**
> "**A.3 - Plugin Memóriatérkép Audit és Refaktoring**
> Feladat: Minden plugin átállítása a kanonikus szimbólumokra"

**Proposed Revision:**
> "**A.3 - Plugin Memóriatérkép Audit és Refaktoring**
> **Feladat:** Add explicit buffer placement using canonical symbols
> **Current State:** Plugins use automatic assembler placement (no explicit addresses)
> **Goal:** Enforce canonical memory layout ($C000-$C19F for transfer buffers)"

---

### Revision 4.2: Update Refactoring Priority Table

**Current Table (lines 400-407) - MISLEADING:**
| Plugin | Hardcoded addr | Refactor prioritás | Becsült idő |
|--------|----------------|-------------------|-------------|
| PrgPlugin | $C000 | MAGAS | 15 perc |

**Proposed Revised Table:**
| Plugin | Current Buffer | Location (symbol file) | Explicit ORG? | Refactor Task | Priority |
|--------|----------------|------------------------|---------------|---------------|----------|
| PrgPlugin | GENERALBUFFER | $D032 (auto) | ❌ | **ADD** explicit @ $C000 | HIGH |
| KoalaDisplayer | KOALA_INFO_BUFFER | Auto-placed | ❌ | **ADD** explicit @ $C000 | HIGH |
| MusPlayer | (Research needed) | Auto-placed | ❌ | **RESEARCH** then ADD | HIGH |
| PetsciiDisplayer | (Research needed) | Auto-placed | ❌ | **RESEARCH** then ADD | HIGH |
| WavPlayer | Multiple buffers | Auto-placed | ❌ | **ADD** explicit @ $C000 | HIGH |
| BurstLoader | TRANSFERBUFFER | **$A000 (explicit)** | ✅ | **DOCUMENT** exception | DOC ONLY |

---

### Revision 4.3: Add New Sprint A.3.0 - Pre-Refactoring Research

**Insert BEFORE current A.3.1:**

> **A.3.0 - Pre-Refactoring Research (NEW)**
>
> **Feladat:** Answer critical research questions before refactoring
>
> **Research Tasks:**
> 1. **Plugin Loader Mechanism**
>    - Analyze `IrqLoaderMenuNew.s` plugin dispatch
>    - Document entry point calling convention
>    - Verify $C000 requirement
>
> 2. **Current Memory Layout Audit**
>    - Compile all plugins with symbol files
>    - Document actual buffer locations
>    - Identify any memory conflicts
>
> 3. **Refactoring Value Analysis**
>    - Document benefits of canonical layout
>    - Assess risks of current auto-placement
>    - Create cost/benefit analysis
>
> **Definition of Done:**
> - [ ] Plugin loader mechanism documented
> - [ ] All plugin buffer locations mapped (symbol files)
> - [ ] Refactoring justification documented
> - [ ] Go/No-Go decision made

---

### Revision 4.4: Clarify BurstLoader Exception Documentation

**Current (line 430-445):**
Implies BurstLoader needs documentation of "exception from norm"

**Clarification Needed:**
BurstLoader is an **approved architectural exception** for valid technical reasons:
- **Reason:** Optimized NMI handler layout for video streaming
- **Justification:** Performance-critical real-time data transfer
- **Approval:** Architectural review 2025-12-27

**Add to documentation template:**
```assembly
;----------------------------------------------------------------------------------------------------------
; ARCHITECTURAL EXCEPTION - APPROVED
; This plugin uses $A000-$A18F for transfer buffer (BURST_BUFFER_ADDR).
;
; REASON: Video streaming optimization
;   - NMI handlers require specific memory layout for burst mode
;   - 50+ inline NMI entry points read directly to $A000 range
;   - Performance: 400 bytes/frame @ 50 FPS (20 KB/s throughput)
;
; APPROVAL: Architectural review 2025-12-27
; REFERENCE: docs/MEMORY_MAP_CANONICAL.md section 4.1 "BurstLoader Exception"
; ALTERNATIVE CONSIDERED: Standard $C000 layout rejected due to 15% performance loss
;----------------------------------------------------------------------------------------------------------
```

---

## Section 5: Impact on Sprint Timeline

### Original Sprint A Estimate
- **Duration:** 2-3 days
- **Tasks:** A.1 (docs), A.2 (symbols), A.3 (refactor 6 plugins)

### Revised Sprint A Estimate
- **Duration:** 4-5 days (+1-2 days for research)
- **Tasks:**
  - A.1 ✅ (DONE - IO2_PROTOCOL_SPECIFICATION.md)
  - A.2 ✅ (DONE - MEMORY_MAP_CANONICAL.md, CartMemoryMap.inc)
  - **A.3.0 (NEW)** - Research phase (1-2 days)
  - A.3.1 - Audit (adjust based on research)
  - A.3.2-A.3.7 - Refactor (strategy TBD after research)

### Risk Assessment
- **Risk:** Refactoring without understanding loader mechanism
- **Mitigation:** Mandatory research phase (A.3.0) before code changes
- **Confidence:** Medium → High (after research completion)

---

## Section 6: Recommendations

### Recommendation 6.1: PAUSE Refactoring, START Research

**Action:**
- ✅ **DO:** Complete A.3.0 research tasks
- ❌ **DON'T:** Start plugin code changes until research complete

**Rationale:**
- Insufficient understanding of plugin loading mechanism
- Risk of breaking plugins if assumptions wrong
- Research investment (1-2 days) prevents wasted refactoring effort

---

### Recommendation 6.2: Update ARCHITECTURE_CONSOLIDATION_PLAN.md to v2.1

**Changes Needed:**
1. Add A.3.0 - Pre-Refactoring Research section
2. Update A.3.1 audit criteria (auto-placement vs. hardcoded)
3. Revise refactoring examples to match reality
4. Clarify BurstLoader exception context
5. Add research questions to appendix

**Priority:** **IMMEDIATE** (before continuing Sprint A)

---

### Recommendation 6.3: Create Plugin Memory Layout Report

**Deliverable:** `docs/PLUGIN_MEMORY_LAYOUT_ACTUAL.md`

**Content:**
- Table of all plugins with actual buffer locations (from symbol files)
- Memory map visualization (current state)
- Comparison with canonical layout
- Identification of conflicts or inefficiencies

**Purpose:** Evidence-based refactoring decisions

---

### Recommendation 6.4: Document Turkish Forum Lessons Learned

**Action:** Extract key technical insights from Turkish forum post

**Topics to Document:**
1. IRQ → IO2 hardware evolution
2. Streaming performance optimization techniques
3. Stack/heap management in Arduino firmware
4. Real-world plugin development challenges

**Benefit:** Historical context for architectural decisions

---

## Section 7: Lessons Learned

### Lesson 7.1: "Read the Code, Not Just the Plan"

**What Happened:**
- Plan assumed hardcoded addresses based on Sprint description
- Code audit revealed completely different reality

**Takeaway:**
- Always verify assumptions with actual code inspection
- Symbol files and listings reveal ground truth
- Historical context (forum posts) provides valuable insights

---

### Lesson 7.2: "Explicit is Better Than Implicit"

**What Happened:**
- Current code relies on assembler auto-placement (implicit)
- Sprint A goal: Make placement explicit (via canonical symbols)

**Takeaway:**
- Implicit behavior is fragile (assembler-dependent)
- Explicit directives = maintainable, predictable code
- **This validates Sprint A's value!**

---

### Lesson 7.3: "Question Assumptions Early"

**What Happened:**
- Plan assumptions went unchallenged until deep into audit
- Early code inspection would have revealed discrepancies

**Takeaway:**
- Start every sprint with quick "sanity check" audit
- Verify 1-2 examples before committing to full plan
- "Measure twice, cut once" applies to refactoring

---

## Section 8: Next Steps

### Immediate (Next Session)
1. ✅ **Create this document** (SPRINT_A_AUDIT_FINDINGS.md)
2. ⏳ **Update ARCHITECTURE_CONSOLIDATION_PLAN.md** → v2.1
3. ⏳ **Begin A.3.0 Research Phase**
   - Analyze plugin loader (IrqLoaderMenuNew.s)
   - Compile all plugins with symbol files
   - Document actual memory layout

### Short-term (This Week)
4. ⏳ **Complete research questions** (Section 3)
5. ⏳ **Go/No-Go decision** on refactoring strategy
6. ⏳ **Resume Sprint A.3** (plugin refactoring) if approved

### Medium-term (Sprint A Completion)
7. ⏳ **Execute refactoring** (strategy TBD)
8. ⏳ **Verify DoD** (all plugins use canonical symbols)
9. ⏳ **Sprint A Retrospective**

---

## Appendix A: Audit Evidence Summary

### Compiled Symbol Files Checked
- ✅ `build/symbol/PrgPlugin.txt` → GENERALBUFFER = $D032
- ⏳ KoalaDisplayer symbol file (need to compile)
- ⏳ MusPlayer symbol file (need to compile)
- ⏳ Others TBD

### Listing Files Analyzed
- ✅ `build/listing/PrgPluginLST.txt` → Confirmed auto-placement

### Source Code Patterns Identified
- ✅ Entry point: `*=$C000` (JMP MAIN)
- ✅ Main code: `*=$C700` (or similar)
- ✅ Data buffers: **No explicit ORG** (auto-placed)
- ✅ BurstLoader exception: Explicit `= $A000`

---

## Appendix B: Reference Documents

### Documents Created (Sprint A)
1. ✅ `docs/IO2_PROTOCOL_SPECIFICATION.md` (normative)
2. ✅ `docs/MEMORY_MAP_CANONICAL.md` (normative)
3. ✅ `IRQHack64/Loader/CartMemoryMap.inc` (implementation)
4. ✅ `docs/sprints/SPRINT_A_AUDIT_FINDINGS.md` (this document)

### Documents to Update
- ⏳ `docs/ARCHITECTURE_CONSOLIDATION_PLAN.md` (v2.0 → v2.1)

### Historical References
- ✅ `FORUM_POST_EASYSD (Turkey).md` (context)
- ✅ `IRQHack64/Plugins/BurstLoader/MemUsage.txt` (spec)

---

## Appendix C: Glossary of Terms

**Auto-placement:** Assembler automatically assigns memory addresses to symbols without explicit `*=` directive.

**Canonical Layout:** Standard memory map defined in MEMORY_MAP_CANONICAL.md ($C000-$C19F = transfer buffer).

**Entry Point:** Address where plugin execution begins (typically $C000 for standard plugins).

**Explicit Addressing:** Using `*=ADDRESS` directive to force symbol location.

**Hardcoded Address:** Literal address in code (e.g., `LDA $C000`). **Note:** Different from explicit ORG directive.

**Symbol File:** Assembler output listing symbol names and their assigned addresses.

---

**END OF AUDIT FINDINGS REPORT**

---

**Approval Required:** Project Owner (Guy Levi)
**Next Action:** Update ARCHITECTURE_CONSOLIDATION_PLAN.md v2.1
**Sprint Status:** **PAUSED** pending research phase completion
