# PCB Bringup Notes
*First hardware test session on PCB — 2026-03-13*

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

## Next Test Plan

**Goal:** Full `T` self-test on PCB hardware

**Hardware to prepare:**
1. Arduino Nano on PCB
2. SD card reader module on PCB, SD card inserted (D: drive, test files present)
3. 100nF ceramic + 10–47µF electrolytic directly at SD module VCC/GND
4. External 5V connected to PCB 5V rail
5. USB COM4 connected to laptop

**Run test:**
```bash
python Tools/test_arduino_comm.py COM4 --verbose
# or manually: open serial at 57600 baud, send 'T'
```

**Expected:** 8/8 PASS (or at minimum SD_INIT, OPEN_RD_CL, SEEK, OPEN_NOEX, MEM_STAB, ROOT_LIST, DIR_NAV — WR_DEL historically marginal even on breadboard)

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

**Note on EEPROM (AT27C512R-45PU):** The EEPROM chip provides CBM80 autostart and the initial NMI handler. Without it, the C64 boots to BASIC normally (after the bus conflict fix), but EasySD cannot auto-start. The EEPROM is a required component for the full cartridge functionality.
