# EasySD Plugin Hardware Bug Investigation

**Status:** Open — boot/menu/nav/PRG and sima MultiLoad bundles are stable; EASYLOAD chain
and most media plugins still fail on real hardware.
**Date:** 2026-04-25 (post 0.7 cleanup)
**Scope:** Real-hardware plugin status on PCB v3. The firmware baseline itself is stable
for boot to BASIC, SEL-triggered menu entry, directory navigation, PRG loading, and
sima MultiLoad PRG bundles. This document tracks what remains broken beyond that baseline.

---

## 1. Status Table

| Plugin | Extension | VICE | Real HW |
|--------|-----------|------|---------|
| KernalBridge (PRG loader) | `.PRG` | ✅ | ✅ working |
| MultiLoad — sima PRG bundle | `.PRG` | ✅ | ✅ working (`MULTILOAD/GAME/` folders) |
| MultiLoad — EASYLOAD chain | `.PRG` (EASYLOAD) | ✅ | ❌ hangs after `JMP ($008B)` with **outer = black, inner = blue** fingerprint |
| HWTest (signal test) | `.HWT` | ✅ | ❌ not yet re-verified on current baseline |
| WavPlayer | `.WAV` | ✅ | ❌ not yet re-verified on current baseline |
| KoalaDisplayer | `.KOA` | ✅ | ❌ not yet re-verified on current baseline |
| PetsciiDisplayer | `.PET` | ✅ | ❌ not yet re-verified on current baseline |
| CvdPlayer | `.CVD` | ✅ | ❌ not yet re-verified on current baseline |

**Important status rule:** unless a plugin has been explicitly re-tested on the present
firmware/hardware baseline, do not downgrade the whole firmware state because of older
plugin notes. Keep the stable baseline and plugin-specific status separate.

**Baseline clarification for PRG debugging:**
- Ordinary menu `.PRG` launches currently do **not** go through `PRGPLUGIN.PRG` /
  KernalBridge.
- They use the direct `PROGRAM` path (`LoadAndLaunchFile()` + `LoaderStub`).
- On 2026-04-26 that direct path was fixed to recognise hybrid BASIC `SYS` stubs
  at `$0801`; Beach Head-style PRGs are now part of the stable real-hardware baseline.

---

## 2. EASYLOAD Chain Hang — Primary Open Issue

### Fingerprint

**Updated 2026-04-26:** On real hardware, the system now advances beyond the earlier
black/blue color state. Characters appear on screen after `JMP ($008B)`, indicating
the game's first part is executing and writing screen data. The chain is progressing
further than before; `RL_HANDLER` / the resident hook is now the active suspect.

Earlier fingerprint (pre-2026-04-26): outer border = black, inner area = blue with
no screen content — that described MAIN finishing and the game taking control of
colors, but the screen remaining blank because the first chain LOAD failed silently.

### Suspects (ordered by likelihood)

1. **`RL_STUB` at `$033C` is wiped by the game.** Many multiload titles nullify
   `$0200-$03FF` during init. The patched `$0330/$0331` Kernal LOAD vector still points
   into the (now zero-filled) cassette buffer, so the next LOAD executes BRK ($00) →
   game IRQ handler → hang. **This matches the black/blue fingerprint exactly**: the
   game's first part has run far enough to set its colors and clear `$0200-$03FF`, then
   died on its first request to load the next part.
   - **Test plan**: drop a canary byte at `$033F`, check after first LOAD whether it
     survived. If wiped, hypothesis confirmed and `RL_STUB` must be relocated.

2. **`RL_WaitProcessing` has no timeout.** The Arduino has a 200 ms stale-identifier
   reset, but the C64 polls forever. Asymmetric handshake → deadlock if any byte is
   lost during the chain.

3. **`RL_HANDLER` at `$E800+` overlaps with game-data load region** for some titles.

4. **`rl_chdir_to_game` empty-path branch** (`ResidentLoader.s:412-417`) silently skips
   chdir if `rl_dir_path_area[0] == $00`.

### Why border-color debug does NOT help here

The `--ml-debug-borders` markers (see Section 5) only cover MAIN. By the time the chain
hangs, MAIN has finished and the game has taken over both `$D020/$D021` colors. Debug
must move into `RL_HANDLER` or use a hardware logic analyzer.

---

## 3. Why Legacy VICE Tests Were Misleading

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
In the legacy VICE/debug build (`DEBUG=1`) this was a no-op. Those emulator-only tests
never exercised the hardware handshake path. A VICE pass meant "protocol logic is
correct"; it did not validate timing or hardware responsiveness.

---

## 4. Protocol Architecture (confirmed correct by analysis)

### 4.1 Arduino→C64 Response Mechanism

When C64 sends a command byte via IO2, the Arduino (in `HandleApi`) dispatches it and calls
`HandleResponse(SUCCESSFUL=0x80, 1)`:

```cpp
SetPage(0);          // clear data bus
SetPage(0);          // clear again — guarantees a low→non-zero edge
SetPage(0x80);       // assert 0x80 on D0-D7
delay(1);            // hold for 1 ms
```

`SetPage(0x80)` drives PORTD[4:7] and PORTC[0:3] to represent 0x80 on the C64 data bus.
C64 reads `$80AB` (any ROML address works — `$80AB` is just an alias, Arduino drives all
of D0-D7).

### 4.2 PROT_WaitProcessing Timing Analysis

| Event | Time from command completion |
|-------|------------------------------|
| ISR enqueues command byte | ~0 µs |
| Arduino `HandleApi` → `GetByte` → dispatch | ~15 µs |
| `GetArgumentsStatic(0)` returns | ~17 µs |
| `HandleResponse` → `SetPage(0x80)` asserted | ~27 µs |
| C64 `PROT_WaitProcessing` 9 NOPs finish | ~9 µs |
| C64 first `LDA $80AB` poll | ~12 µs |
| C64 reads 0x80 (success window = 1000 µs) | by ~30 µs |

**Conclusion: timing is adequate with large margin.** `SetPage(0x80)` is asserted within
27 µs; C64 starts polling at 12 µs and has 1000 µs to catch it. Not the failure point
under normal timing.

### 4.3 NMI Routing (confirmed correct in all configurations)

| $01 value | NMI vector reads from | Path to TransferHandler |
|-----------|----------------------|------------------------|
| `$37` (normal) | Kernal ROM `$FFFA/$FFFB` = `$FE43` | `$FE43: SEI; JMP ($0318)` → `$0318` = `$80AF` |
| `$35` (handler) | RAM `$FFFA/$FFFB` = `$0368` | `$0368: JMP ($0318)` → `$0318` = `$80AF` |
| `$34` (P2TK) | RAM `$FFFA/$FFFB` = `$80AF` | direct → `$80AF` |

`$0318` is set to `$80AF` (TransferHandler) by the boot stub at cold start. `RL_INSTALL`
does NOT modify `$0318`, so TransferHandler remains active throughout.
`PROT_ReceiveFragmentNoCallback` re-sets `$0318 = $80AF` before every receive
(belt-and-suspenders). ROML (`$8000–$9FFF`) is accessible in all three `$01` modes
because /EXROM=LOW (8K game mode).

### 4.4 KernalBridge → EASYLOAD.PRG Session Handover

KernalBridge intentionally omits `PROT_EndTalking` before jumping to `EASYLOAD.PRG`
("protocol leak"). When EASYLOAD.PRG calls `PROT_StartTalking`, the identifier bytes
`$64,$46,$17` arrive as data in the Arduino's `readQueue` (already in `IN_TRANSMISSION`
state). These are processed as command bytes 24, 70, 100 — none of which exist in the
switch statement. They are silently ignored. No default case, no state corruption.
This is architecturally harmless.

---

## 5. Known Confirmed Bugs

**Important:** the confirmed bugs below describe bridge/plugin-path issues. They do
not describe the current direct `PROGRAM` → `LoaderStub` launcher used for ordinary
menu `.PRG` selection.

### BUG-1: KernalBridge Code Overflow into I/O Space ($D000–$D113)

**Severity:** High
**File:** `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s`
**Location:** `MAIN` + functions span `$C700–$D113`

The C64 I/O area `$D000–$DFFF` contains VIC-II, SID, CIA1, CIA2 registers. With the
default `$01=$37`, reads from `$D000–$D113` return hardware register values, not code.
CPU execution reaching any address in `$D000–$D113` will execute garbage opcodes.

**Status:** Pre-existing issue; only affects code paths that reach those addresses.
Large PRGs triggering deep call stacks may hit this. Needs fix: shrink KernalBridge
below `$CFFF`. This was **not** the root cause of the Beach Head regression, because
the current ordinary `.PRG` menu path bypasses KernalBridge.

### BUG-2: PROT_WaitProcessing Bypassed in Legacy DEBUG=1 Builds

**Severity:** Medium (architectural confidence gap, not a crash bug per se)
**File:** `EasySD/Loader/CartLibHi.s:30–32`

Legacy VICE plugin tests gave a false green signal. The hardware polling loop in
`PROT_WaitProcessing` still needs validation on real C64 hardware with serial logs
or a logic analyzer.

**Fix:** hardware debugging with border-color markers (see Section 6).

### BUG-3: workingFile Left Open After KernalBridge P2TK

**Severity:** Low
**File:** `EasySD/Loader/Bridges/KernalBridge/KernalBridge.s:543`

After P2TK transfers `EASYLOAD.PRG`, the file handle is left open (no `CLOSEFILE`
command sent). When `MultiLoad.s` subsequently calls `PROT_OpenFile("LOADER")`, the
`workingFile = sd.open(...)` assignment overwrites the old open handle. SdFat 2.x's
assignment operator closes the previous file before opening the new one (verified by
SdFat source), so no file descriptor is leaked. FAT has no hardware file-locking
mechanism.

**Status:** Benign. Not considered the root cause of the EASYLOAD chain hang.

---

## 6. Hardware Debug Plan — Border Color Markers (sima MultiLoad MAIN only)

Border color markers in `MultiLoad.s MAIN` are guarded by `.if ML_DEBUG_BORDERS`.
This is useful when `MAIN` itself fails — **it does NOT cover the EASYLOAD chain hang**
described in Section 2 (post-MAIN, the game owns the colors).

### 6.1 Color Scheme

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

### 6.2 Build Instructions

```bash
# Build MultiLoad template with border-color markers:
python Tools/build.py multiload --ml-debug-borders

# Then generate a game-specific bundle:
python Tools/create_multiload.py --from-disk GAME.d64 \
    --template EasySD/build/plugins/bootplugin.prg
```

Use a release-style build (`DEBUG=0`) so `PROT_WaitProcessing` follows the real
hardware path.

---

## 7. Next Steps (Priority Order)

1. **Test the `RL_STUB` wiped hypothesis** for the EASYLOAD chain hang. Add a canary
   byte at `$033F`, capture its state after the first LOAD via the resident hook.

2. **If confirmed**: relocate `RL_STUB` out of `$0200-$03FF` (e.g. into a KernalBridge
   gap or a dedicated bridge page that survives game init). Add a C64-side timeout
   to `RL_WaitProcessing` to mirror Arduino's 200 ms reset.

3. **Re-verify media plugins on current baseline** (WavPlayer, KoalaDisplayer,
   PetsciiDisplayer, CvdPlayer, HWTest). Earlier "READY → freeze" notes pre-date the
   current firmware and may no longer reflect the actual symptom.

4. **Fix KernalBridge overflow** (BUG-1): shrink `$C700–$D113` code below `$CFFF`.
   This requires identifying which functions can be removed or merged.

---

*Document refreshed for 0.7 cleanup pass on 2026-04-25.*
