# EasySD Plugin Hardware Bug Investigation

**Status:** Open — boot/menu/nav/PRG are stable; most media plugins still need
re-verification on real hardware.
**Date:** 2026-05-05
**Scope:** Real-hardware plugin status on PCB v3. The firmware baseline itself is
stable for boot to BASIC, SEL-triggered menu entry, directory navigation, and
single-file PRG loading. This document tracks what remains broken beyond that
baseline.

---

## 1. Status Table

| Plugin | Extension | VICE | Real HW |
|--------|-----------|------|---------|
| KernalBridge (PRG loader) | `.PRG` | ✅ | ✅ working |
| HWTest (signal test) | `.HWT` | ✅ | ❌ not yet re-verified on current baseline |
| WavPlayer | `.WAV` | ✅ | ❌ not yet re-verified on current baseline |
| KoalaDisplayer | `.KOA` | ✅ | ❌ not yet re-verified on current baseline |
| PetsciiDisplayer | `.PET` | ✅ | ❌ not yet re-verified on current baseline |
| CvdPlayer | `.CVD` | ✅ | ❌ not yet re-verified on current baseline |

**Important status rule:** unless a plugin has been explicitly re-tested on the
present firmware/hardware baseline, do not downgrade the whole firmware state
because of older plugin notes. Keep the stable baseline and plugin-specific
status separate.

**Baseline clarification for PRG debugging:**
- Ordinary menu `.PRG` launches currently do **not** go through `PRGPLUGIN.PRG`
  / KernalBridge.
- They use the direct `PROGRAM` path (`LoadAndLaunchFile()` + `LoaderStub`).
- On 2026-04-26 that direct path was fixed to recognise hybrid BASIC `SYS` stubs
  at `$0801`; Beach Head-style PRGs are now part of the stable real-hardware
  baseline.

---

## 2. Why Legacy VICE Tests Were Misleading

`PROT_WaitProcessing` in `CartLibHi.s` compiles differently by build type:

```asm
PROT_WaitProcessing:
.if DEBUG = 1
    CLC         ; ← VICE path: always success, returns immediately
    RTS
.else
    NOP × 9     ; ← real hardware path: poll loop
-   LDA CARTRIDGE_BANK_VALUE   ; read $80AB (data bus D0-D7 from ROML)
    BEQ -       ; loop until non-zero
    BPL +       ; bit7=0 → SEC (error)
    CLC         ; bit7=1 (= 0x80+) → CLC (success)
    RTS
+   SEC
    RTS
.endif
```

Every plugin that fails on real hardware calls `PROT_WaitProcessing` multiple
times. In the legacy VICE/debug build (`DEBUG=1`) this was a no-op. Those
emulator-only tests never exercised the hardware handshake path. A VICE pass
meant "protocol logic is correct"; it did not validate timing or hardware
responsiveness.

---

## 3. Protocol Architecture (confirmed correct by analysis)

### 3.1 Arduino→C64 Response Mechanism

When C64 sends a command byte via IO2, the Arduino (in `HandleApi`) dispatches
it and calls `HandleResponse(SUCCESSFUL=0x80, 1)`:

```cpp
SetPage(0);          // clear data bus
SetPage(0);          // clear again — guarantees a low→non-zero edge
SetPage(0x80);       // assert 0x80 on D0-D7
delay(1);            // hold for 1 ms
```

`SetPage(0x80)` drives PORTD[4:7] and PORTC[0:3] to represent 0x80 on the C64
data bus. C64 reads `$80AB` (any ROML address works — `$80AB` is just an alias,
Arduino drives all of D0-D7).

### 3.2 PROT_WaitProcessing Timing Analysis

| Event | Time from command completion |
|-------|------------------------------|
| ISR enqueues command byte | ~0 µs |
| Arduino `HandleApi` → `GetByte` → dispatch | ~15 µs |
| `GetArgumentsStatic(0)` returns | ~17 µs |
| `HandleResponse` → `SetPage(0x80)` asserted | ~27 µs |
| C64 `PROT_WaitProcessing` 9 NOPs finish | ~9 µs |
| C64 first `LDA $80AB` poll | ~12 µs |
| C64 reads 0x80 (success window = 1000 µs) | by ~30 µs |

**Conclusion: timing is adequate with large margin.** `SetPage(0x80)` is
asserted within 27 µs; C64 starts polling at 12 µs and has 1000 µs to catch
it. Not the failure point under normal timing.

### 3.3 NMI Routing (confirmed correct in all configurations)

| $01 value | NMI vector reads from | Path to TransferHandler |
|-----------|----------------------|------------------------|
| `$37` (normal) | Kernal ROM `$FFFA/$FFFB` = `$FE43` | `$FE43: SEI; JMP ($0318)` → `$0318` = `$80AF` |
| `$35` (handler) | RAM `$FFFA/$FFFB` = `$0368` | `$0368: JMP ($0318)` → `$0318` = `$80AF` |
| `$34` (P2TK) | RAM `$FFFA/$FFFB` = `$80AF` | direct → `$80AF` |

`$0318` is set to `$80AF` (TransferHandler) by the boot stub at cold start.
`PROT_ReceiveFragmentNoCallback` re-sets `$0318 = $80AF` before every receive
(belt-and-suspenders). ROML (`$8000–$9FFF`) is accessible in all three `$01`
modes because /EXROM=LOW (8K game mode).

---

## 4. Known Confirmed Bugs

**Important:** the confirmed bugs below describe bridge/plugin-path issues.
They do not describe the current direct `PROGRAM` → `LoaderStub` launcher used
for ordinary menu `.PRG` selection.

### BUG-1: KernalBridge Code Overflow into I/O Space ($D000–$D113)

**Severity:** High
**File:** `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s`
**Location:** `MAIN` + functions span `$C700–$D113`

The C64 I/O area `$D000–$DFFF` contains VIC-II, SID, CIA1, CIA2 registers. With
the default `$01=$37`, reads from `$D000–$D113` return hardware register
values, not code. CPU execution reaching any address in `$D000–$D113` will
execute garbage opcodes.

**Status:** Pre-existing issue; only affects code paths that reach those
addresses. Large PRGs triggering deep call stacks may hit this. Needs fix:
shrink KernalBridge below `$CFFF`. This was **not** the root cause of the
Beach Head regression, because the current ordinary `.PRG` menu path bypasses
KernalBridge.

### BUG-2: PROT_WaitProcessing Bypassed in Legacy DEBUG=1 Builds

**Severity:** Medium (architectural confidence gap, not a crash bug per se)
**File:** `EasySD/Loader/CartLibHi.s:30–32`

Legacy VICE plugin tests gave a false green signal. The hardware polling loop
in `PROT_WaitProcessing` still needs validation on real C64 hardware with
serial logs or a logic analyzer.

---

## 5. Next Steps (Priority Order)

1. **Re-verify media plugins on current baseline** (WavPlayer, KoalaDisplayer,
   PetsciiDisplayer, CvdPlayer, HWTest). Earlier "READY → freeze" notes
   pre-date the current firmware and may no longer reflect the actual symptom.

2. **Fix KernalBridge overflow** (BUG-1): shrink `$C700–$D113` code below
   `$CFFF`. This requires identifying which functions can be removed or merged.
