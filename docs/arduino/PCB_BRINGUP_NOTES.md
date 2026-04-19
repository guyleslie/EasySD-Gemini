# PCB Bringup Notes
*Historical bringup and investigation notes for PCB hardware sessions.*

This file is a session log, not the canonical source of current feature status.
For current behavior, verify against the source code first.

Terminology used here:
- **cartridge ROML chip** = the external cartridge memory device on the PCB
- **MCU internal EEPROM** = the ATmega328P built-in EEPROM used by the Arduino firmware

## Setup
- Arduino Nano 3.x on PCB (socketed)
- SD card reader module connected to PCB
- USB COM4 → laptop (only power source)
- 100nF ceramic cap on PCB 5V/GND rail (after Nano)
- Debug firmware: 30684B (99% flash), uploaded via USBtinyISP

---

## Issue 1: Debug firmware too large to compile

**Symptom:** `text section exceeds available space in board` (30860B > 30720B limit)

**Root cause:** Two recent commits added 612B to the debug build:
- `ead0c4d` — EEPROM last-dir persistence (`SaveLastDir` + `RestoreLastDir`): +500B
- `6daf01c` — `COMMAND_GET_PATH` handler (`HandleGetPath`): +112B

**Fix applied in `Arduino/EasySD/CartApi.cpp`:**
1. Replace byte-by-byte `EEPROM.update()` loop → `eeprom_update_block()` (avr-libc)
2. Replace byte-by-byte `EEPROM.read()` loop → `eeprom_read_block()` (avr-libc)
3. Remove `strlen`/validation from `SaveLastDir` — always write 64 bytes, `RestoreLastDir` handles edge cases
4. Simplify `RestoreLastDir` path parser: `if (!slash) break` instead of `p + strlen(p)`
5. Remove 3 debug log calls from new functions (SaveLastDir, RestoreLastDir, HandleGetPath)
6. Split `HandleGetPath` 256-byte transmit loop into two loops (eliminates per-iteration conditional)
7. Remove low-value `LOGD(SYS, "Done")` from transfer completion

**Result:** 30684B (99%), 36B margin. Fits.

**Lesson:** Debug build margin is razor-thin (~36B). Every new feature that adds debug logs risks overflow. Use `eeprom_update_block`/`eeprom_read_block` instead of inline loops — they are smaller and already in avr-libc.

---

## Issue 2: USB upload fails (stk500 not in sync)

**Symptom:** avrdude reports `not in sync: resp=0x53 0x44...` ("SD FAIL" in ASCII)

**Root cause:** The running sketch outputs serial data at 57600 baud. avrdude receives sketch output instead of bootloader response. The DTR auto-reset pulse triggers a reboot, the bootloader runs for ~2 seconds but avrdude cannot sync in time — possibly a CH340 driver timing issue on this specific Nano clone.

**Confirmed:** Same failure on bare Nano (off PCB) and on PCB — not a PCB-specific issue.

**Workaround: use USBtinyISP**

build.py `arduino-upload-isp` has a bug: looks for hex in wrong directory. Use avrdude directly:

```bash
"C:\Users\guyle\AppData\Local\Arduino15\packages\arduino\tools\avrdude\6.3.0-arduino17\bin\avrdude.exe" \
  -C "C:\Users\guyle\AppData\Local\Arduino15\packages\arduino\tools\avrdude\6.3.0-arduino17\etc\avrdude.conf" \
  -v -p atmega328p -c usbtiny -B10 \
  "-Uflash:w:C:\Users\guyle\AppData\Local\arduino\sketches\61398A5C2D5C2F5FC0E8639CC6B96A6F\EasySD.ino.hex:i"
```

**Speed:** `-B10` (100kHz) = ~2.5 min for 30KB. Acceptable for occasional uploads.

**Important:** ISP upload performs chip erase → **bootloader is erased**. USB upload will not work after ISP upload until bootloader is restored. All future uploads must use ISP.

**TODO:** Fix `arduino_upload_isp()` in `build.py` — correct hex path is:
`C:\Users\guyle\AppData\Local\arduino\sketches\61398A5C2D5C2F5FC0E8639CC6B96A6F\EasySD.ino.hex`
not `Arduino/EasySD/build/arduino.avr.nano/EasySD.ino.hex`

---

## Issue 3: SD card fails to initialize on PCB (USB-only power)

**Symptom:** 3× `SD init failed` at startup. Self-test `OPEN_RD_CL: FAIL`, `SEEK: FAIL`, `WR_DEL: FAIL`.

**Root cause:** SD module powered via Arduino Nano's 5V pin from USB. The Nano has a schottky diode between USB VBUS and the 5V pin → ~0.3–0.5V drop → SD module gets ~4.6V. Under SD write current spikes (~100mA, ~1µs), voltage dips below the SD module's AMS1117-3.3 regulator minimum → init fails, SPI errors.

**SD card itself is fine:** FAT32, all test files present (`TESTDATA.BIN`, `TESTFILE.TXT`, `BIGFILE.BIN`, `TESTDIR/INNER.TXT`).

**Fix: add external 5V to PCB 5V rail + proper decoupling at SD module**

```
Laptop USB → Arduino Nano (COM4, serial only)
External 5V ──────────────────────────────── PCB 5V rail
                                   │
                              [100nF ceramic]  ← already present elsewhere, move here
                              [10–47µF elko]   ← ADD THIS
                                   │
                              SD module VCC/GND
```

**Capacitor placement rules learned:**
- Caps only effective when placed directly at the consumer (SD module VCC/GND pins)
- Caps placed far away (even 5cm) are partly nullified by wire/trace inductance
- Arduino Nano has its own internal bypass caps — no external caps needed at Nano side
- The existing PCB 100nF "after the Nano" is too far from SD module to help SD init

**Safe to run external 5V + USB simultaneously:** Nano's schottky diode allows both sources. The higher-voltage source drives the rail; both coexist safely.

**Cheap SD modules:** typically have 100nF ceramic near the SD slot, but no bulk capacitance for the 5V input. Always add 10–47µF electrolytic externally near the SD module on any PCB.

---

## PCB v3 + C64 hardware test results (2026-04-05/06)

**Hardware self-test (debug firmware, COM4):** 8/8 PASS — SD_INIT, OPEN_RD_CL, SEEK, OPEN_NOEX, WR_DEL, MEM_STAB, ROOT_LIST, DIR_NAV. RAM: 413B free (stable).

**Full system test (release firmware, real C64):** historical session snapshot from an earlier menu-autoload firmware run:
- Cold boot: EasySD menu auto-loads ✅
- Directory navigation (enter/back) ✅
- File listing and scrolling ✅
- Short MENU button: reload menu ✅
- Long MENU button: exit to BASIC ✅
- PETSCII, KOA, WAV, MUS, CVD, HWT plugins: ✅
- MultiLoad games: not yet working (separate investigation pending)

This section records what was observed in that session. It should not override newer source-level investigation or later dedicated status tracking by itself.

---

## Issue 4: C64 freezes immediately on power-on with PCB v3 (real hardware)

*Discovered 2026-04-05 — first real C64 test with PCB v3*

**Symptom:** C64 powers on with PCB inserted: BASIC startup text partially visible, display slightly shifted, no cursor, system frozen.

**Root cause: data bus bus conflict**

`CartInterface::Init()` called `SetAddressPinsOutput()`, which set D4-D7 (PORTD bits 4-7) and A0-A3 (PORTC bits 0-3) permanently as OUTPUT, driving `0x00` on all 8 C64 data bus lines from the moment Arduino boots (~300ms after power-on).

During this time, EXROM=HIGH (cartridge disabled). The C64 is in normal mode and reads KERNAL/BASIC ROM opcodes. The Arduino's 0x00 output conflicts with the ROM drivers — neither wins cleanly, resulting in indeterminate bus voltages. The 6510 CPU reads near-`$00` data (BRK instruction), enters IRQ/BRK handling, then executes from a garbage vector → freeze.

**Why VICE passed:** VICE emulates the protocol correctly but does not model bus contention. The test suite never exercised real bus timing.

**Fix applied (`CartInterface.cpp`):**
1. Removed `SetAddressPinsOutput()` from `Init()` — data bus pins start as INPUT (tristate)
2. `EnableCartridge()` now sets DDRD[4:7] and DDRC[0:3] to OUTPUT *before* pulling EXROM LOW
3. `DisableCartridge()` now sets them back to INPUT *after* raising EXROM HIGH

```
Before:           After:
Init()            Init()
  SetAddressPins→OUTPUT  (removed)
  IOSetup→EXROM=HIGH     IOSetup→EXROM=HIGH, data=INPUT
                         [C64 runs normally, no bus conflict]

EnableCartridge()        EnableCartridge()
  EXROM=LOW              DDRD|=0xF0, DDRC|=0x0F  ← OUTPUT first
                         EXROM=LOW

DisableCartridge()       DisableCartridge()
  EXROM=HIGH             EXROM=HIGH
                         DDRD&=~0xF0, DDRC&=~0x0F ← tristate
```

**Flash impact:** 23690B (77%, +0B net — no size change).

**Cartridge ROML chip role (AT27C512R-45PU):** The external cartridge ROML chip is a permanent, required component — not optional.
It provides three things the system cannot function without:
1. **CBM80 string at $8004–$8008** — triggers C64 cartridge autostart instead of BASIC boot
2. **Cold-start code at $8009** — initialises hardware, sets software NMI vector `$0318` = `$8066`
3. **NMI data handler at $8066** — receives each byte from Arduino (`LDA $80AB`) and stores it to C64 RAM; this is how `TransferMenu()` fills RAM with the menu program

Without the cartridge ROML chip installed: C64 boots to BASIC (no freeze after fix), but MENU button does nothing useful — CBM80 check fails, `$0318` stays at KERNAL default (`$FE66` = RTI), all NMI transfers are silently discarded.

---

## Issue 5: CBM80 check fails even with cartridge ROML chip — TransferMenu() data bus timing

*Discovered 2026-04-05 during root-cause analysis*

**Root cause: ATmega output overrides cartridge ROML chip during CBM80 window**

The original `TransferMenu()` called `EnableCartridge()` before `ResetC64()`.
`EnableCartridge()` sets D4–D7 / A0–A3 as OUTPUT (value = 0x00 from last `SetPage(0)`).

The C64 CBM80 check at `$8004–$8008` happens ~2–5 ms into the 300 ms delay after reset.
At that moment ROML is active, and both the cartridge ROML chip and Arduino drive the same bus lines:

```
Cartridge ROML chip output (AT27C512R): IOH_max ≈ 4 mA  (CMOS source)
ATmega328P output:          IOL_max = 40 mA (strong sink)
```

ATmega always wins: bus reads 0x00 on every bit. CBM80 check sees `$00,$00,$00,$00,$00`
instead of `$C3,$C2,$CD,$38,$30` → no autostart → menu never loads.

**Fix applied (`CartApi.cpp`, `CartInterface.cpp/.h`):**

Split `TransferMenu()` into two phases:

| Phase | Call | Data bus | EXROM |
|---|---|---|---|
| 1 — CBM80 window | `EnableExromOnly()` + `ResetC64()` + `delay(300)` | INPUT (tristate) | LOW |
| 2 — NMI transfers | `EnableDataBus()` + `SendHeader()` + transfer loop | OUTPUT | LOW |

New `CartInterface` methods:
- `EnableExromOnly()` — EXROM LOW only, DDR unchanged (data stays tristate)
- `EnableDataBus()` — sets DDRD[4:7] and DDRC[0:3] OUTPUT

`EnableCartridge()` is unchanged and still used by streaming paths (HandleStream, etc.)
where the C64 is already running and CBM80 is not a concern.

**Flash impact:** 23700B (77%, +10B).

---

## Current firmware state (updated 2026-04-18)

The current firmware model is **BASIC-first on cold boot**:
- Power-on: AVR holds C64 `/RESET` LOW during SD/runtime init
- Release: firmware returns the cartridge interface to a BASIC-safe idle state
- Result: C64 boots to BASIC, not directly to the menu
- Short MENU/SEL press: `TransferMenu()`
- Long MENU/SEL press: release strictly after the 1000 ms threshold → `ResetNoCartridge()` → BASIC

Recent firmware cleanups on top of the earlier bus fixes:

| Fix | Effect |
|---|---|
| Data bus tristate at idle | C64 no longer freezes on power-on with PCB inserted |
| Data bus tristate during CBM80 window | cartridge ROML chip can present CBM80 + NMI handler correctly |
| Reset line changed to active push-pull drive | cold-boot BASIC release no longer depends on the AVR internal pull-up |
| BASIC-safe release path centralized | cold boot and long-press BASIC reset now use the same cartridge-hidden/session-reset path |
| Data bus latch clear before INPUT | "tristate" state no longer leaves weak pull-ups on the C64 data bus |

**Verified boot behaviour (cartridge ROML chip installed):**

| Action | Result |
|---|---|
| Cold boot (C64 + Arduino power on together) | Intended behavior: C64 boots to BASIC after AVR init |
| Short MENU button press (≤1000 ms) | C64 resets, EasySD menu loads |
| Long MENU button press (>1000 ms) | `ResetNoCartridge()` — C64 resets to BASIC |
| Cold boot without cartridge ROML chip | BASIC `READY.` — no freeze; MENU button resets to BASIC only |

Current startup policy:
- Cold boot always targets BASIC first; menu is explicit, not automatic.
- Menu loads from root when invoked.
- Do not restore the saved last directory during `CartApi::Init()`.
- Keep MCU internal EEPROM path storage for later/manual reuse, but exclude it from the cold-boot path.

**Flash:** 23708 / 30720 B (77%, 7012 B free). **RAM:** 1284 / 2048 B (764 B free).

### Hardware caveat observed after repeated bench use

Later hardware sessions uncovered a likely **mechanical/contact issue** on the current bench unit:
- the EasySD PCB has been inserted/removed from the C64 cartridge port many times
- the SD module is connected through pin headers/female sockets
- moving the EasySD PCB while the C64 is held in reset can make the Arduino power LED blink and the C64 proceed to BASIC

Interpretation:
- this points to intermittent power, ground, reset, or edge-connector contact integrity
- such faults can mimic firmware boot/reset timing problems
- startup anomalies on this specific hardware should therefore be interpreted with caution unless the physical connection quality is known-good

---

## Investigation: MENU button (A6 analog-only) — 2026-04-06

**Circuit (led button.png schematic):**
```
+5V → R2 (10kΩ) → MENU/RESET node → SW1 (tact switch) → GND
```
- This node is the local PCB button input on Arduino A6. It is not the C64 cartridge port reset line.
- Not pressed: A6 = +5V (pulled high via R2)
- Pressed: A6 = GND (switch closes)

**Firmware (`CartInterface.h`):**
```cpp
inline bool selRead() { return analogRead(SEL) >= 512; }
```

ATmega328P, 5V Vcc, ADC range 0–1023:
- Not pressed (A6 = +5V): `analogRead` ≈ 1023 → returns **TRUE**
- Pressed (A6 = GND): `analogRead` ≈ 0 → returns **FALSE**

**`EasySD.ino` loop() state machine:**
```
!selRead() + stateNone   → statePressed    (button down)
 selRead() + statePressed → stateReleased  (button up)
   elapsed > 1000 ms → ResetNoCartridge()
   elapsed ≤ 1000 ms → TransferMenu()
```

**Verdict: implementation is correct.** Full analysis:

| Question | Result |
|---|---|
| Schematic matches firmware? | Yes — pull-up to +5V, switch to GND, selRead() logic correct |
| SPI conflict with A6? | None — SPI on D10-D13, A6/ADC6 is independent |
| Pull-up needed in firmware? | No — external 10kΩ handles it; INPUT_PULLUP would not work on analog-only A6 anyway |
| ADC threshold correct? | Yes — 512 = 2.5V; button drives to 0V or 5V, never ambiguous |
| Hardware debounce? | Missing (no cap across SW1) — state machine handles this adequately |
| Button missed during HandleApi()? | Yes, by design — cooperative loop, no issue in practice |

No changes needed in firmware or hardware for the MENU button.

---

## Investigation: cartridge ROML chip A8-A11 wiring — root-cause analysis — 2026-04-06

**Question:** Cartridge ROML chip A8-A11 are connected to Arduino A0-A3 (ROM_A8-A11 net), not directly to
C64 expansion port A8-A11. Is this a hardware design flaw?

**Answer: No. This is correct by design — identical to the original IRQHack64.**

### Actual cartridge ROML chip wiring (clarified 2026-04-06)

```
ROML chip A0-A7   ← C64 A0-A7  (byte offset within page)
ROML chip A8-A11  ← Arduino A0-A3  (PORTC[0:3])
ROML chip A12-A15 ← Arduino D4-D7  (PORTD[4:7])
ROML chip D0-D7   ← C64 D0-D7  (data bus)
ROML chip OE#/CE# ← C64 ROML
```

C64 A8-A15 are NOT connected to the cartridge ROML chip at all. Arduino controls all 8 upper address bits.

### SetPage(byte) — dual-purpose operation

`SetPage(N)` writes to PORTD[4:7] = `N & 0xF0` and PORTC[0:3] = `N & 0x0F`. This simultaneously:
1. **Drives C64 data bus** with byte N (D4-D7 upper nibble + D0-D3 lower nibble)
2. **Selects cartridge ROML chip page N** (A12-A15 upper nibble + A8-A11 lower nibble = N)

This is why `IRQLoaderRom.bin` has 256 pages where page N has all placeholder bytes = N:
whichever page the Arduino selects, the cartridge ROML chip would output that same value N from every
placeholder position — but the Arduino always wins (40mA sink vs ROML chip 4mA source) during
NMI transfers, so the selected ROML page content is irrelevant then.

### Why it works

**Phase 1 — CBM80 check window (EnableExromOnly, data bus tristate):**
- Arduino A0-A3 and D4-D7 are INPUT (tristate); PORTD[4:7]=0 and PORTC[0:3]=0 (default)
- ROML chip A8-A15 float near 0V (last driven value was 0, held by parasitic capacitance)
- ROML chip selects page 0 → presents CBM80 bytes at $8004-$8008 ✅
- Arduino does not drive D0-D7 → ROML chip output reaches C64 data bus undisturbed ✅

**Phase 2 — NMI data transfers (EnableDataBus, Arduino drives bus):**
- `SetPage(dataValue)` sets the cartridge ROML chip page to `dataValue` and drives C64 bus with `dataValue`
- Arduino (40mA) overrides ROML chip output (4mA) — C64 reads Arduino's data ✅
- ROML page content is irrelevant during NMI transfers

**Phase 3 — EXROM HIGH (DisableCartridge):**
- ROML inactive → ROML chip OE# deasserted → output disabled ✅

### Original IRQHack64 comparison

The original IRQHack64 uses the same dual-purpose wiring (Arduino controls all cartridge ROML chip upper
address bits + C64 data bus simultaneously). The design is intentional and correct.


### Summary: earlier C64 issues were firmware-visible, but later bench anomalies are not assumed firmware-only

| Issue | Root cause | Fix | Commit |
|---|---|---|---|
| C64 freezes on power-on | `SetAddressPinsOutput()` in `Init()` drove D4-D7/A0-A3 OUTPUT=0 from boot, conflicting with C64 bus | Removed from `Init()` — data bus stays tristate until `EnableCartridge()` | `8964487` |
| CBM80 check fails with cartridge ROML chip installed | `EnableCartridge()` called before `ResetC64()` — ATmega drove D0-D7 during CBM80 window, overriding the cartridge ROML chip output | Split into `EnableExromOnly()` + `delay(300)` + `EnableDataBus()` | `b8dc98e` |
| Directory navigation freezes on ENTER | `ENTERDIR` in `EasySDMenu.s` called `PROT_ChangeDirectory` without prior `PROT_SetNameZ` — Arduino received length=0, returned error, C64 froze in `CHANGEDIRFAIL` | Added `LDX NAMELOW / LDY NAMEHIGH / JSR PROT_SetNameZ` before the call; also improved `CHANGEDIRFAIL` error recovery and `GOBACK` error handling | `3a46be7` |
| Early cold-boot BASIC release remained marginal | reset release and cartridge idle-state handling were split across multiple paths | reset drive changed to active HIGH/LOW and BASIC-safe release was centralized | 2026-04-18 cleanup series |

Firmware fixes addressed several real issues. However, the later observed "touch the cartridge and the LED blinks / BASIC appears" behavior is a hardware integrity symptom and should not be folded back into a firmware-only conclusion.

**Note:** The directory navigation bug and several bus-timing issues were invisible in VICE and Arduino serial tests — only real C64 hardware exposed them. The later intermittent contact symptom is a separate hardware-quality concern.
