# EasySD Plugin Hardware Bug Investigation

**Status:** Open — hardware debugging in progress
**Date:** 2026-04-12
**Scope:** Common real-hardware plugin failures on PCB v3. MultiLoad notes below include both the historical hang report and the current post-fix retest status.

---

## 1. Symptom

Several non-trivial plugins fail on real C64 hardware (PCB v3, ATmega328P, Optiboot).
The same plugins pass in VICE with `debug-vice` builds.

| Plugin | Extension | VICE | Real HW |
|--------|-----------|------|---------|
| KernalBridge (PRG loader) | `.PRG` | ✅ | ✅ working |
| HWTest (signal test) | `.HWT` | ✅ | ✅ working |
| WavPlayer | `.WAV` | ✅ | ❌ hang |
| KoalaDisplayer | `.KOA` | ✅ | ❌ hang |
| MusPlayer | `.MUS` | ✅ | ❌ hang |
| PetsciiDisplayer | `.PET` | ✅ | ❌ hang |
| CvdPlayer | `.CVD` | ✅ | ❌ hang |
| MultiLoad | `.PRG` (EASYLOAD) | ✅ | ⚠️ historical hang on older build; current code needs hardware re-test |

**Historical MultiLoad failure:** on the older hardware-debug build, black outer border + dark blue inner border appeared immediately, then the system hung indefinitely.

**Current status:** MultiLoad source changed materially on 2026-04-12. The resident loader now preserves the game's NMI vector during transfers, no longer destroys unrelated IRQ sources, returns X/Y correctly from the resident stub, and the first-part config field now stores the full filename including `.PRG` in 20 bytes. The Multiload template builds cleanly and the existing VICE PRG-load suite still passes, but the current MultiLoad code has not yet been re-verified on real hardware.

So the old border-color observation is still useful as a historical clue, but it must not be treated as the final current-state verdict.

---

## 2. Why VICE Tests Are Misleading

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

Every plugin that fails on real hardware calls `PROT_WaitProcessing` multiple times.
In VICE (`DEBUG=1`) this is a no-op. In all VICE plugin tests, the hardware handshake
path is **never exercised**. VICE passes = "protocol logic is correct"; it does not validate
timing or hardware responsiveness.

---

## 3. Protocol Architecture (confirmed correct by analysis)

### 3.1 Arduino→C64 Response Mechanism

When C64 sends a command byte via IO2, the Arduino (in `HandleApi`) dispatches it and calls
`HandleResponse(SUCCESSFUL=0x80, 1)`:

```cpp
SetPage(0);          // clear data bus
SetPage(0);          // clear again
SetPage(0x80);       // assert 0x80 on D0-D7
delay(1);            // hold for 1 ms
```

`SetPage(0x80)` drives PORTD[4:7] and PORTC[0:3] to represent 0x80 on the C64 data bus.
C64 reads `$80AB` (any ROML address works — `$80AB` is an alias, Arduino drives all of D0-D7).

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

**Conclusion: timing is adequate with large margin.** `SetPage(0x80)` is asserted within 27 µs;
C64 starts polling at 12 µs and has 1000 µs to catch it. Not the failure point under normal timing.

### 3.3 NMI Routing (confirmed correct in all configurations)

| $01 value | NMI vector reads from | Path to TransferHandler |
|-----------|----------------------|------------------------|
| `$37` (normal) | Kernal ROM `$FFFA/$FFFB` = `$FE43` | `$FE43: SEI; JMP ($0318)` → `$0318` = `$80AF` |
| `$35` (handler) | RAM `$FFFA/$FFFB` = `$0368` | `$0368: JMP ($0318)` → `$0318` = `$80AF` |
| `$34` (P2TK) | RAM `$FFFA/$FFFB` = `$80AF` | direct → `$80AF` |

`$0318` is set to `$80AF` (TransferHandler) by the EEPROM boot stub at cold start.
`RL_INSTALL` does NOT modify `$0318`, so TransferHandler remains active throughout.
`PROT_ReceiveFragmentNoCallback` re-sets `$0318 = $80AF` before every receive (belt-and-suspenders).
ROML (`$8000–$9FFF`) is accessible in all three `$01` modes because /EXROM=LOW (8K game mode).

### 3.4 KernalBridge → EASYLOAD.PRG Session Handover

KernalBridge intentionally omits `PROT_EndTalking` before jumping to `EASYLOAD.PRG` ("protocol leak").
When EASYLOAD.PRG calls `PROT_StartTalking`, the identifier bytes `$64,$46,$17` arrive as data
in the Arduino's `readQueue` (already in `IN_TRANSMISSION` state). These are processed as command bytes
24, 70, 100 — **none of which exist in the switch statement**. They are silently ignored. No default
case, no state corruption. This is architecturally harmless.

### 3.5 What Is Different: KernalBridge (works) vs. Plugins (fail)

KernalBridge is a **menu plugin** — loaded by the EasySD menu. It starts a fresh session
(Arduino `receiveState = IDLE`). The identifier bytes go through the state machine normally.

All other plugins are also loaded by the EasySD menu via KernalBridge or the built-in plugin
loader. The initial `PROT_StartTalking` from within a plugin runs in the same state as
KernalBridge. There is no apparent structural difference that should cause failure.

### 3.6 MultiLoad Source Changes Since The Original Hardware Report

The original MultiLoad hang notes in this file were written before the latest resident-loader fixes.
The following changes are now present in source and must be considered before drawing conclusions
from the older report:

- `ML_FIRST_PART_NAME` is now 20 bytes, so the first-part filename is stored with the `.PRG` suffix.
- `RL_ReceiveFragmentNoCallback` now saves and restores `$0318/$0319` instead of permanently overwriting the game's soft NMI vector.
- `RL_DisableInterrupts` now disables only CIA2 NMI sources; it no longer wipes VIC and CIA1 IRQ sources.
- `RL_STUB` now preserves the handler's X/Y return values and delays `CLI` until after `$01` has been restored.

These changes reduce the chance that the old MultiLoad hang diagnosis still points at the same root cause.

---

## 4. Known Confirmed Bugs

### BUG-1: KernalBridge Code Overflow into I/O Space ($D000–$D113)

**Severity:** High
**File:** `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s`
**Location:** `MAIN` + functions span `$C700–$D113`

The C64 I/O area `$D000–$DFFF` contains VIC-II, SID, CIA1, CIA2 registers.
With the default `$01=$37`, reads from `$D000–$D113` return hardware register values, not code.
CPU execution reaching any address in `$D000–$D113` will execute garbage opcodes.

**Status:** Known pre-existing issue; only affects code paths that reach those addresses.
Large PRGs triggering deep call stacks may hit this. Needs fix: shrink KernalBridge below `$CFFF`.

### BUG-2: PROT_WaitProcessing Bypassed in DEBUG=1 — VICE Tests Don't Validate Hardware Path

**Severity:** Medium (architectural confidence gap, not a crash bug per se)
**File:** `EasySD/Loader/CartLibHi.s:30–32`

VICE plugin tests give a false green signal. The hardware polling loop in `PROT_WaitProcessing`
has never been isolated-tested outside of KernalBridge. While analysis confirms the timing
is adequate, there may be a real-hardware-specific edge case (e.g. VIC bad-line stealing at
an unlucky moment, SD card SPI stall extending Arduino response time, or a border case in the
IO2 bit-receive timing that corrupts a command byte before `PROT_WaitProcessing` is reached).

**Fix:** Hardware debugging with border-color markers (see Section 5).

### BUG-3: workingFile Left Open After KernalBridge P2TK

**Severity:** Low
**File:** `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s:543`

After P2TK transfers `EASYLOAD.PRG`, the file handle is left open (no `CLOSEFILE` command sent).
When `MultiLoad.s` subsequently calls `PROT_OpenFile("LOADER")`, the `workingFile = sd.open(...)`
assignment overwrites the old open handle. SdFat 2.x's assignment operator closes the previous
file before opening the new one (verified by SdFat source), so no file descriptor is leaked.
Effect on SD card state: none. FAT has no hardware file-locking mechanism.

**Status:** Benign. Not considered the root cause of the current MultiLoad investigation.

---

## 5. Hardware Debug Plan — Border Color Markers

The only definitive way to find the exact failure point is a debug build that changes the
C64 border color (`$D020`) at each stage of plugin execution.

### 5.1 Color Scheme

| Color | Value | Stage |
|-------|-------|-------|
| White | 1 | MAIN entered (after JMP) |
| Red | 2 | ML_SAVESTATE done |
| Cyan | 3 | RL_INSTALL done |
| Purple | 4 | PROT_StartTalking done |
| Green | 5 | PROT_Send(COMMAND_GET_PATH) done |
| Blue | 6 | PROT_WaitProcessing returned (CLC = success) |
| Yellow | 7 | PROT_ReceiveFragmentNoCallback done |
| Orange | 8 | PROT_OpenFile returned (CLC = success) |
| Light red | 10 | First page read done |
| Dark grey | 11 | JMP to game — success (never seen if hang earlier) |

**Error colors:**
- PROT_WaitProcessing returns SEC (error): `$D020 = 2` + hang
- PROT_OpenFile returns SEC: `$D020 = 9` (brown)

### 5.2 Interpretation

| Observed border color | Hang location |
|----------------------|---------------|
| White (1) | Hang in ML_SAVESTATE or RL_INSTALL |
| Cyan (3) | Hang in PROT_StartTalking |
| Purple (4) | Hang in PROT_Send(COMMAND_GET_PATH) |
| Green (5) | Hang in PROT_WaitProcessing — **most likely** |
| Blue (6) | WaitProcessing OK; hang in ReceiveFragmentNoCallback |
| Yellow (7) | Path received OK; hang in PROT_OpenFile |
| Orange (8) | OpenFile OK; hang in GetFileInfo or subsequent |

### 5.3 Build Instructions

The debug markers are compiled in when `ML_DEBUG_BORDERS=1` is passed to the MultiLoad build.
Use a release-style build (`DEBUG=0`) so `PROT_WaitProcessing` follows the real hardware path.

```bash
# Build MultiLoad template with border-color markers:
python Tools/build.py multiload --ml-debug-borders

# Then generate a game-specific ZIP or EASYLOAD from that template:
python Tools/create_multiload.py --from-disk GAME.d64 \
    --template EasySD/build/plugins/bootplugin.prg
```

`Tools/build.py multiload --ml-debug-borders` is the current supported way to build the border-debug template.

### 5.4 Source Changes

Border color markers are added to `MultiLoad.s MAIN` guarded by `.if ML_DEBUG_BORDERS`:

```asm
MAIN:
    .if ML_DEBUG_BORDERS
    LDA #1 : STA $D020        ; WHITE: MAIN entered
    .endif
    JSR ML_SAVESTATE
    .if ML_DEBUG_BORDERS
    LDA #2 : STA $D020        ; RED: SAVESTATE done
    .endif
    JSR RL_INSTALL
    ...etc
```

See `MultiLoad.s` source for complete implementation.

---

## 6. Next Steps (Priority Order)

1. **Re-test current MultiLoad on real hardware before assuming the old hang still reproduces.**
    The source changed significantly on 2026-04-12, so the first question is whether MultiLoad still hangs at all on the updated build.

2. **If it still hangs, build the border-color debug binary** (see 5.3) and test on PCB v3 hardware.
    Record the border color when the system hangs → narrows failure to one stage.

3. **Based on result:**
   - If hangs at Green (5) → `PROT_WaitProcessing` never getting 0x80:
     - Check if `noInterrupts()` in `HandleReadFile` is still in effect (it shouldn't be)
     - Add Arduino serial debug print before and after `HandleResponse` in `HandleGetPath`
     - Verify with logic analyser: does /NMI stay low? Does data bus change?
   - If hangs at Blue (6) → NMI transfers not completing:
     - Check `$0318` value in RAM before `PROT_ReceiveFragmentNoCallback`
     - Verify `ZP_IRQ_STATE_WAITHANDLE` is being cleared
   - If hangs at Yellow (7) → file open failing:
     - Add Arduino serial debug for `HandleOpenFile` result
     - Check `currentPath` on Arduino matches expected `/MULTILOAD/GAMENAME/`

4. **Fix KernalBridge overflow** (BUG-1): shrink `$C700–$D113` code below `$CFFF`.
   This requires identifying which functions can be removed or merged.

5. **Once root cause found:** fix the specific issue, then validate all failing plugins
   in order (WAV → KOA → MUS → PET → CVD each may have additional plugin-specific bugs).

---

## 7. Other Plugin Failure Notes

The failing plugins still strongly suggest a **common real-hardware root cause** rather than fully
independent per-plugin bugs. However, MultiLoad should no longer be used as a frozen reference case
without qualification, because its resident-loader code has changed since the original hardware notes.

If current MultiLoad now works on hardware, that result becomes a useful divider: the remaining plugin
hangs are then less likely to be caused by the exact same bug.

Plugin-specific bugs (if any) will only become visible AFTER the common root cause is fixed.

**WavPlayer** has additional known issues unrelated to this investigation:
see `docs/plugins/WavPlayer.md` and the WavPlayer memory file for CIA timing and mode details.

---

*Document updated from current source state on 2026-04-12. Real-hardware retest results still pending for the latest MultiLoad build.*
