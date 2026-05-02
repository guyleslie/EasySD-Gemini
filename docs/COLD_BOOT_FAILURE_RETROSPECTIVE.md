# Cold Boot Failure Retrospective

Date: 2026-05-02

## Status

**RESOLVED.** The "BASIC text, no cursor" cold-boot symptom is fixed by reverting
the cold-boot architecture to match the original IRQHack64 baseline
(https://github.com/nejat76/IRQHack64). Verified on real C64 hardware
(uEliteBoard64 (uni64.com)), both debug and release builds, on 2026-05-02.

The fix has two components, **both of which were required**:

1. **Firmware**: stop holding C64 `/RESET` LOW during AVR cold boot.
2. **Hardware**: remove parasitic loads (Pi1541, IEC2SD) from the C64 power rail.

This document captures the diagnosis path and what to remember for any future
boot regression.

## Symptom Recap

- Cold boot (C64 + EasySD + SD card fully without power for >20 s, then power on):
  - BASIC banner text appears.
  - **Cursor does not blink.**
  - Keyboard appears unresponsive.
- Cold boot **without an SD card**: reaches BASIC with a blinking cursor.
- Warm reset / long SEL BASIC reset: reaches BASIC normally.

The non-blinking cursor specifically points at the C64 CIA1 Timer A IRQ chain not
running after the kernel banner was printed. The kernel printed the banner
(meaning the cold-reset sequence reached at least that far), but the IRQ chain
that drives cursor blink (CIA1 Timer A → `$0314` IRQ vector → kernel handler)
did not start. Either the `I` flag was left set, CIA1 Timer A never started, or
`/IRQ` was held permanently asserted by some external source.

## What Changed Between IRQHack64 (working) and EasySD (failing)

Source comparison against the original IRQHack64 firmware:

| | IRQHack64 (worked) | EasySD before fix |
|---|---|---|
| `/RESET` during AVR boot | HIGH from `IOSetup` (released, never held LOW) | **LOW for 470–1000 ms** while AVR ran SD init |
| `PHI2` line | **Not wired, not read** anywhere | A4 wired to cartridge port PHI2; `syncBusChangeToPhi2Low()` called on every cartridge state change |
| Data bus when cartridge "disabled" | Always driven (page byte stays latched) | **Tristated** (`DDRD &= ~0xF0`, `DDRC &= ~0x0F`) plus PORT pull-up clear |
| AVR–C64 cold-boot sync | None — C64 free-runs its own RC; AVR catches up | AVR actively held C64 in reset until SD was ready |

EasySD also has a **BASIC-first** cold-boot policy (menu loads only on SEL
press). This made the original reason for the `/RESET` hold obsolete — the hold
remained in code purely as residual architecture from the previous
"menu-on-cold-boot" model.

## Root Cause

**The 470–1000 ms `/RESET` hold during AVR cold boot was the primary cause.**

The C64's own reset chip (typically a 556 in monostable mode) generates a clean
~50 ms LOW pulse on power-on. The C64 chip set (VIC-II, CIA1, CIA2, SID) is
designed to come out of reset on that timing. EasySD held it LOW for 470–1000 ms
(`delay(300)` + SD init time). During the extended hold, VIC-II is in reset, so
PHI2 is not generated and DRAM is not refreshed; the chips' internal state
machines see a non-standard reset pattern and end up in a state where the
kernel's IRQ chain cannot start, even though the kernel ROM cold-init still
completes far enough to print the BASIC banner.

The PHI2 monitoring and data-bus tristate logic were not the cause; reverting
only the `/RESET` hold (Test A in the diagnosis plan) was sufficient to fix the
symptom on hardware.

The **SD-card-presence flip** (cold boot without SD card worked) is explained by
the failed `initSD()` retries (3 × 200 ms) extending the total reset hold to
~970 ms, which evidently lands on a window where the C64 internal state is
different. This is not a fix; it just shifted the failure window.

## Hardware Co-requirement

During validation it became clear that a Pi1541 (Raspberry Pi Zero) attached to
the C64 power rail of the test uEliteBoard64 (uni64.com) was an additional destabilizing
factor. Removing it was a co-required fix alongside the firmware revert. The
Pi1541 acted as a parasitic load on the 5 V rail and pulled the supply
sufficiently to disturb cold-boot timing on its own.

For any future "cold boot regression" report:
- power down all auxiliary devices on the C64 first (Pi1541, IEC2SD, etc.);
- only then attribute the symptom to firmware or to the cartridge.

## Why Earlier Investigations Did Not Find This

Every earlier firmware change stayed **inside the `/RESET` hold paradigm**:
single-edge vs double-edge release, longer/shorter LOW dwell, pre- vs post-SD
init ordering, PHI2 sync wait variants. None questioned whether the reset hold
should exist at all. The original IRQHack64 baseline was never used as a
reference point.

The system is electrically coupled (C64, AVR, SD module, cartridge port,
auxiliary devices on the C64 power rail) but only firmware was ever changed.
Without signal-level measurement and without considering external power loads,
every firmware change was a hypothesis without evidence.

## What Was Removed in the Fix

Code (Arduino/EasySD):

- `BootState` enum and the `bootState` global variable in `EasySD.ino` —
  telemetry-only, never read; removed.
- The boot state machine in `setup()` — replaced with a simple linear
  `cartInterface.Init()` → `delay(300)` → `initSD()` → `cartApi.Init()`.
- `CartInterface::ReleaseColdBootToBasic()` — function and declaration removed
  from `CartInterface.cpp` / `CartInterface.h`. `EnterBasicSafeMode()` and
  `ReleaseToBasic(bool)` are kept, used by the warm-reset path
  (`ResetNoCartridge()`).

Behavior change:

- `IOSetup()` now drives `/RESET` HIGH from the start, not LOW.

What was deliberately NOT removed:

- PHI2 wiring (A4) and `syncBusChangeToPhi2Low()` / `WaitForStablePhi2()` —
  these were not the root cause and they are still useful for `TransferMenu()`
  and similar bus transitions; left in place.
- Data bus tristate at idle — orthogonal to the cold-boot fix; left in place.

## Logic Analyzer Capture Plan (kept for reference)

If a future cold-boot regression appears, capture the real signals before
changing firmware. The Seengreat SG Nano DLA (8 ch, 24 MHz) is sufficient.

| CH | Signal | Source | Purpose |
|----|--------|--------|---------|
| 1 | `/RESET` | Cartridge port C | Trigger reference; verify edge cleanliness |
| 2 | `/EXROM` | Cartridge port 9 | Confirm HIGH throughout cold boot |
| 3 | `PHI2` | Cartridge port E | Confirm clock stabilizes after reset edge |
| 4 | `/IRQ` | Cartridge port 4 | **Critical**: must pulse ~16.6 ms (CIA1 60 Hz) for cursor blink |
| 5 | `/NMI` | Cartridge port D | Confirm HIGH (de-asserted) — no spurious NMI |
| 6 | `D0` (or `D7`) | Cartridge port 21 (or 14) | Glitch detection on data bus |
| 7 | AVR D9 | AVR pin 9 | See exactly when AVR drives `/RESET` HIGH |
| 8 | SD `CS` (D10) or `SCK` (D13) | AVR pin 10 / 13 | Correlate SD activity with C64 boot phase |

Trigger: rising edge on CH1 (`/RESET`).
Pre-trigger: 100 ms. Post-trigger: 1 s.

## Lessons For Future Boot Debug

1. **When in doubt, compare against a known-working baseline** — IRQHack64
   in this case. A divergence can be a regression that has been there for
   months.
2. **Power-rail loads matter** — auxiliary devices on the C64 power
   (Pi1541, IEC2SD, modems) can mask or unmask firmware bugs. Test in
   isolation first.
3. **Don't keep iterating inside one paradigm** — if every variant of an
   approach fails, question the approach itself.
4. **A "BASIC-first" boot policy doesn't need AVR to hold `/RESET`** — the
   C64 boots to BASIC by itself; firmware just needs to ensure EXROM is HIGH
   and data bus is tristate before the C64 starts. Anything beyond that is
   over-engineering.
