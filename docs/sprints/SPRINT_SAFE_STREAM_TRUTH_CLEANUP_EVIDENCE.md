# SafeStream Truth Cleanup - Evidence Summary

**Sprint:** SPRINT_SAFE_STREAM_TRUTH_CLEANUP
**Date:** 2026-01-01
**Author:** Claude Sonnet 4.5
**Status:** Phase 1 Complete - Evidence Gathering

---

## Executive Summary

The "SafeStream" abstraction in IRQHack64 is **fundamentally misleading**. The code creates the illusion of configurable streaming parameters (interval, chunk, delay) with three profiles (SAFE, NORMAL, FAST), but:

1. **The Arduino firmware completely ignores all three parameters**
2. **The C64 StreamLargeFile_Internal always passes 0,0,0, overriding any SafeStream profile**
3. **The streaming protocol is inherently request-driven and passive-termination based** - no ISR delays or throttling exist

This sprint documents the evidence proving SafeStream is a "no-op" abstraction that contradicts reality.

---

## PHASE 1A: Internal Evidence (Codebase Truth)

### Finding 1: Arduino Ignores All Parameters

**File:** `Arduino/IRQHack64/CartApi.cpp:905-955`

**Lines 912-915: Parameters are read but NEVER used**
```cpp
void CartApi::HandleStream() {
  DBG_PRINTLN_F("Got HandleStream");
  GetArgumentsStatic(3);
  uint8_t initialDelay = Arguments[0];        // ← READ
  uint8_t countStreamedBytes = Arguments[1];  // ← READ
  uint8_t delayBetweenBytes = Arguments[2];   // ← READ

  // ... NO FURTHER REFERENCES TO THESE VARIABLES! ...

  // Actual streaming logic uses hardcoded values:
  #define DOUBLE_BUFFER_SIZE 64    // Hardcoded, NOT 'countStreamedBytes'
  #define STREAM_TIMEOUT_MS 100    // Hardcoded, NOT 'delayBetweenBytes'
```

**Proof:** Grepped entire `CartApi.cpp` - these variables are declared, assigned, and **never referenced again**.

**Impact:** Any profile parameters (SAFE: 32,16,10 / NORMAL: 64,32,4 / FAST: 64,64,2) sent from C64 have **zero effect** on Arduino behavior.

---

### Finding 2: StreamLargeFile_Internal ALWAYS Passes 0,0,0

**File:** `IRQHack64/Loader/CartLibStream.s:49-63`

**Lines 59-62: Hardcoded zero parameters**
```assembly
StreamLargeFile_Internal:
    SEI                     ; Disable interrupts
    ; ...
    ; Step 1: Initialize stream on Arduino
    ; The current Arduino firmware ignores these parameters, but we send them anyway for future compatibility.
    LDA #$00                ; initialDelay ← ALWAYS ZERO
    LDX #$00                ; countStreamedBytes ← ALWAYS ZERO
    LDY #$00                ; delayBetweenBytes ← ALWAYS ZERO
    JSR IRQ_Stream
    BCS _stream_error
```

**Comment on line 58:**
> "The current Arduino firmware ignores these parameters, but we send them anyway for future compatibility."

**Proof:** This comment **acknowledges** the parameters are ignored, contradicting SafeStream's purpose.

**Impact:** Even if SafeStream_Impl sends profile parameters (e.g., NORMAL = 64,32,4), they are **overridden** by this second IRQ_Stream call.

---

### Finding 3: SafeStream Profiles Are Misleading

**File:** `IRQHack64/Loader/SafeStreamImpl.s:11-28`

**Profiles Defined:**
```assembly
STREAM_PROFILE_SAFE:
    .BYTE 32, 16, 10        ; interval, chunk, delay

STREAM_PROFILE_NORMAL:
    .BYTE 64, 32, 4

STREAM_PROFILE_FAST:
    .BYTE 64, 64, 2
```

**Lines 41-76: SafeStream_Impl sends these to Arduino**
```assembly
SafeStream_Impl:
    ; ...
    ; Compute offset = profile_id * 3
    ; Load interval/chunk/delay from table
    LDA STREAM_PROFILES, X  ; interval
    PHA
    INX
    LDA STREAM_PROFILES, X  ; chunk
    PHA
    INX
    LDA STREAM_PROFILES, X  ; delay
    TAY

    PLA
    TAX
    PLA

    JSR IRQ_Stream  ; ← Sends A, X, Y to Arduino
    RTS
```

**The Lie:**
This code **suggests** that SAFE/NORMAL/FAST profiles will affect streaming behavior (chunk sizes, delays, timing).

**The Truth:**
- Arduino ignores A, X, Y parameters (Finding 1)
- If caller subsequently invokes `StreamLargeFile_Internal`, parameters are reset to 0,0,0 (Finding 2)

**Impact:** Any plugin using `JSR SafeStream_Impl` believes it's tuning performance, but it's a **placebo**.

---

### Finding 4: Only One Active Caller

**Grep:** `SafeStream_Impl` usage across codebase

**Result:**
- **WavPlayer.s:60** - `JSR SafeStream_Impl` (STREAM_NORMAL profile)
- **No other plugins use SafeStream**

**Observation:**
If SafeStream were genuinely useful, more plugins would adopt it. The fact that only WavPlayer uses it (and it has no effect) suggests it's either:
- A failed experiment
- Incomplete refactoring
- Legacy code that should be removed

---

### Finding 5: Contradictory Comments

**File:** `IRQHack64/Loader/CartLibStream.s:16-17`

**Lines 16-17: Warning comment**
```assembly
; *** INTERNAL ONLY - DO NOT CALL FROM MENU/PLUGINS ***
; *** USE SafeStream FOR PUBLIC API ***
```

**Contradiction:**
- Comment says "use SafeStream for public API"
- But `SafeStream_Impl` **does not call** `StreamLargeFile_Internal`
- So SafeStream alone cannot perform streaming (it only sends parameters, then returns)

**File:** `IRQHack64/Loader/CartLibStream.s:58`

**Line 58:**
```assembly
; The current Arduino firmware ignores these parameters, but we send them anyway for future compatibility.
```

**Contradiction:**
- If parameters are "for future compatibility," why does SafeStream present them as **current functionality**?
- The profiles (SAFE/NORMAL/FAST) imply **present-tense** behavior, not future-reserved fields.

---

## PHASE 1B: External Evidence (Commodore Device Communication Patterns)

### Reference 1: IEC Serial Bus Timeout Protocol

**Source:** [Commodore Peripheral Bus: Part 4 - pagetable.com](https://www.pagetable.com/?p=1135)

**Key Quote (from [Commodore Bus - Wikipedia](https://en.wikipedia.org/wiki/Commodore_bus)):**
> "The device addressed must respond in a preset period of time; otherwise, the C64 will assume that the device addressed is not on the bus, and will return an error in the STATUS word."

**Timing Specifications:**
- **EOI timeout:** 200 μs - listener must detect lack of acknowledgment
- **Data line hold:** 20 μs minimum (60 μs for C64 due to VIC-II interrupts)
- **Byte acknowledgment timeout:** 1000 μs maximum for device response

**Relevance:**
Commodore peripherals use **request-driven, timeout-based** communication:
1. Master (C64) issues request
2. Slave (device) **must respond within timeout window**
3. If no response → timeout error, master exits gracefully

This pattern is **identical** to IRQHack64 IO2 streaming:
1. C64 reads $DF00 → /IO2 pulse (request)
2. Arduino ISR places byte on $DE00 (response within ~2μs)
3. If C64 stops requesting → Arduino timeout (100ms) → clean exit

**Conclusion:** Timeout-based passive termination is **standard Commodore peripheral design**, not a missing feature.

---

### Reference 2: Cartridge IO Port Timing Constraints

**Source:** [Lemon64 Forum - Cartridge IO Port Timings](https://www.lemon64.com/forum/viewtopic.php?t=84903)

**Key Finding:**
> "/IO1 and /IO2 are generated by the PLA based on several input signals, however PHI2 is not among them, so if an address between De00 and DfFF appears on the bus while phi2 is low, you'll get a glitch."

**Timing Constraint:**
Address is only valid while PHI2 is high (~500ns window per cycle).

**Implication for Streaming:**
Any Arduino ISR delay would **violate C64 timing requirements**:
- C64 reads $DF00 (IO2 trigger)
- C64 immediately reads $DE00 (data port) - expects stable data **within same PHI2 cycle**
- Arduino ISR MUST complete in < 2μs to meet this constraint

**Why SafeStream Parameters Are Impossible:**
The proposed "delayBetweenBytes" parameter (SAFE=10, NORMAL=4, FAST=2) would require:
- Arduino to **delay** byte delivery by microseconds
- But C64 is **already waiting** in a tight loop (LDA $DF00 / LDA $DE00)
- Any delay → C64 reads stale/garbage data → corruption

**Conclusion:** ISR delays are **architecturally impossible** on this hardware. SafeStream parameters are not just unimplemented - they're **unimplementable**.

---

### Reference 3: VIC-II Interrupt Impact on Timing

**Source:** [Codebase64 - How the VIC/64 Serial Bus Works](https://codebase64.org/doku.php?id=base:how_the_vic_64_serial_bus_works)

**Key Quote:**
> "The 6510 has a different timing to work with a 2nd busmaster (the VIC-II). [...] The address lines aren't stable at the rising edge of phi2 (due to the AEC switching), in worst case it takes additional 80..100ns for the address lines to be valid."

**Implication:**
Even C64's own video chip can interrupt the CPU for **42 μs**, which is why IEC serial bus spec increased timing margins to 60 μs.

**Streaming Decision:**
`StreamLargeFile_Internal` disables interrupts (SEI) during streaming specifically to **avoid VIC-II timing corruption**. This is why:
- No delays can be inserted
- No flow control can be added
- Parameters like "interval" or "chunk" are meaningless

**Conclusion:** The decision to use SEI-protected, uninterruptible streaming is **correct and necessary**. SafeStream profiles that suggest tunable timing are architectural fiction.

---

## Evidence Summary Table

| Evidence Type | Location | Finding | Impact |
|---------------|----------|---------|--------|
| **Arduino Code** | CartApi.cpp:912-915 | Parameters read but never used | SafeStream profiles have zero effect |
| **C64 Code** | CartLibStream.s:59-62 | StreamLargeFile_Internal always passes 0,0,0 | SafeStream parameters are overridden |
| **C64 Code** | SafeStreamImpl.s:11-28 | Three profiles defined with distinct values | Creates illusion of configurable behavior |
| **Call Site** | WavPlayer.s:60 | Only 1 plugin uses SafeStream | Low adoption suggests uselessness |
| **Comments** | CartLibStream.s:58 | "Arduino firmware ignores these parameters" | Code acknowledges parameters are no-op |
| **Comments** | CartLibStream.s:16-17 | "USE SafeStream FOR PUBLIC API" | Contradicts reality (SafeStream doesn't stream) |
| **Architecture** | IO2_PROTOCOL_SPECIFICATION.md | Protocol spec doesn't mention parameters | Official docs ignore SafeStream |
| **External** | Commodore Bus standards | Timeout-based passive termination is standard | Confirms current design is correct |
| **External** | Cartridge IO timing constraints | ISR delays violate PHI2 timing (<500ns) | SafeStream delays are impossible |
| **External** | VIC-II interrupt behavior | SEI protection necessary for timing | Confirms no-parameter design is correct |

---

## Smoking Gun: The Contradiction

**SafeStream Claims:**
Tunable streaming with 3 performance profiles (SAFE/NORMAL/FAST).

**Code Reality:**
1. Arduino: `uint8_t initialDelay = Arguments[0];` → **never referenced again**
2. C64: `LDA #$00 ; initialDelay` → **always zero**
3. Protocol Spec: **no mention of parameters**

**Architectural Reality:**
IO2 cartridge timing constraints **physically prevent** ISR delays.

**Conclusion:**
SafeStream is a **cargo cult abstraction** - it looks like it does something, but it's pure ceremony with no substance.

---

## Recommended Actions (Preview for Phase 2)

**Option A (Conservative):**
- Keep SafeStreamImpl as future-reserved NO-OP wrapper
- Mark parameters as explicitly ignored with clear comments
- Document as "reserved for future protocol versions"

**Option B (Clean Truth):**
- Remove SafeStreamImpl entirely
- Expose StreamLargeFile_Internal as the single canonical streaming API
- Remove all profile/parameter references from documentation

**Decision Criteria:**
- **Minimum risk?** Option A (no behavioral change)
- **Maximum clarity?** Option B (eliminates confusion)
- **Future flexibility?** Option A (reserves parameter space)

---

## Next Steps

**PHASE 2:** Decision - Choose Option A or B based on:
- Risk analysis
- Future protocol extension plans
- User feedback (WavPlayer maintainer)

**PHASE 3:** Implementation (no behavioral changes, only clarity fixes)

**PHASE 4:** Documentation cleanup (eliminate contradictions)

---

## Sources

### Commodore Device Communication Standards:
- [Commodore Peripheral Bus: Part 4 - pagetable.com](https://www.pagetable.com/?p=1135)
- [Commodore bus - Wikipedia](https://en.wikipedia.org/wiki/Commodore_bus)
- [Serial Port - C64-Wiki](https://www.c64-wiki.com/wiki/Serial_Port)
- [How the VIC/64 Serial Bus Works - Codebase64](https://codebase64.org/doku.php?id=base:how_the_vic_64_serial_bus_works)
- [Commodore IEC Serial Bus Manual](https://www.commodore.ca/wp-content/uploads/2018/11/Commodore-IEC-Serial-Bus-Manual-C64-Plus4.txt)

### Cartridge IO Timing:
- [Lemon64 Forum - Cartridge port IO port timings questions](https://www.lemon64.com/forum/viewtopic.php?t=84903)
- [C64 Cartridge on a Stripboard - Linus Akesson](https://www.linusakesson.net/hardware/autostart/index.php)
- [Expansion Port - C64-Wiki](https://www.c64-wiki.com/wiki/Expansion_Port)

---

**End of Evidence Summary**
