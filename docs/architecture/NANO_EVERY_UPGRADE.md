# EasySD — Arduino Nano Every + SRAM Upgrade Design Study

**Status:** Concept / Design Study (not yet implemented)
**Date:** 2026-03-11

This document describes a proposed hardware and software upgrade replacing the current
Arduino Nano 3.x (ATmega328P) + cartridge ROML chip implementation
(AT27C512R-45PU / M27C512 class EPROM device) with an Arduino Nano Every (ATmega4809)
+ 6264 SRAM. It is based on verified hardware data and accurate analysis of the existing
codebase.

---

## 1. Motivation

The current ATmega328P is approaching its limits in two areas:

| Resource | ATmega328P | Actual usage | Headroom |
|----------|-----------|--------------|---------|
| Flash | 32 KB | ~22.7 KB (release) / ~30.2 KB (debug) | 9.5 KB / **472 bytes** |
| SRAM | 2 KB | ~1585 bytes at boot | ~415 bytes |

The debug build uses 98% of flash — adding any new feature can push it over the limit.
SRAM headroom of ~415 bytes means every local array, stack frame and buffer must be
carefully sized.

The Arduino Nano Every (ATmega4809) fits the same DIP socket / header, runs at 5 V and
offers substantially more resources:

| Resource | ATmega328P | ATmega4809 | Gain |
|----------|-----------|-----------|------|
| Flash | 32 KB | 48 KB | +50% |
| SRAM | 2 KB | 6 KB | +200% |
| CPU speed | 16 MHz | 20 MHz | +25% |
| Internal EEPROM | 1 KB | 256 B | −75% (still sufficient) |

The internal EEPROM reduction (256 B) is not a problem: the project only stores
a 64-byte path string + 2 magic bytes = 66 bytes total (`CartApi.cpp`, lines 44–58).

---

## 2. Current Architecture

```
Power-on
  │
  └─ C64 reads $8000–$9FFF (ROML)
       │
       └─ cartridge ROML chip drives data bus
            │
            └─ C64 runs IRQ boot loader from the cartridge ROML chip
                 │
                 └─ Arduino streams menu PRG via NMI → C64 runs menu
```

**Current cartridge ROML chip role:** Static 64 KB EPROM, programmed once (via external programmer).
Contains the IRQ loader binary, replicated at 12 page positions in the 64 KB image
(see `build.py:create_eprom_loader`, `eprom_pos = [171, 166, ...]`). The input binary
(`IRQLoader.65s.bin`) is 256 bytes; the rest of the EPROM image is mostly empty.

**Bus contention (current design):** The Arduino permanently drives D4–D7 / A0–A3
as outputs. During NMI transfers, the Arduino's `SetPage()` overrides the cartridge
ROML chip output by brute force — both are on the bus simultaneously. This works
because the EPROM's drive strength is weak relative to the Arduino, but it is not a
clean design.

---

## 3. Proposed Architecture

Replace the external cartridge ROML chip with a **6264 static SRAM** (8 KB, DIP-28, 5 V). The
Arduino writes the IRQ loader content into the SRAM at power-on while holding the
C64 in reset, then releases reset. The C64 boots from SRAM identically to how it
booted from the cartridge ROML chip.

```
Power-on
  │
  ├─ Arduino starts, asserts /RESET LOW (C64 held in reset)
  ├─ Arduino writes 8 KB boot ROM image to SRAM (boot loader + padding)
  ├─ Arduino releases /RESET
  │
     └─ C64 reads $8000–$9FFF (ROML) — now from SRAM, not the cartridge ROML chip
       │
       └─ (same as before)
```

**Key improvement — clean /OE control:**
The Arduino drives the SRAM's /OE pin. During NMI data transfers, the Arduino
asserts /OE HIGH (SRAM output disabled) before calling `SetPage()`, then
reasserts /OE LOW when the transfer is done. No bus contention.

---

## 4. ATmega4809 Pin Mapping (Authoritative)

Source: official `pins_arduino.h` for the `nona4809` variant.

| Arduino pin | ATmega4809 port.bit | Current use (328P PCB) |
|-------------|---------------------|------------------------|
| D0 | PC5 | — |
| D1 | PC4 | — |
| D2 | **PA0** | IO2 (INT0) |
| D3 | **PF5** | EXROM |
| D4 | **PC6** | Data bus bit 4 |
| D5 | **PB2** | Data bus bit 5 |
| D6 | **PF4** | Data bus bit 6 |
| D7 | **PA1** | Data bus bit 7 |
| D8 | **PE3** | /NMI |
| D9 | **PB0** | /RESET (→C64) |
| D10 | **PB1** | SD /CS |
| D11 | **PE0** | MOSI (SPI) |
| D12 | **PE1** | MISO (SPI) |
| D13 | **PE2** | SCK (SPI) |
| A0 (D14) | **PD3** | Data bus bit 0 |
| A1 (D15) | **PD2** | Data bus bit 1 |
| A2 (D16) | **PD1** | Data bus bit 2 |
| A3 (D17) | **PD0** | Data bus bit 3 |
| A4 (D18) | **PF2** | SEL (C64 /RESET input) |
| A5 (D19) | **PF3** | STATUS LED |
| A6 (D20)* | **PD4** | — |
| A7 (D21)* | **PD5** | — |

*Castellated solder pads only — not on standard through-hole header.

**Critical problem with current PCB on Nano Every:**
D4–D7 (data bus bits 4–7) map to PC6, PB2, PF4, PA1 — four different ports.
A single `SetPage()` call currently writes two port registers (PORTD + PORTC on 328P).
On the ATmega4809, bits 4–7 cannot be written with fewer than 4 separate register
accesses, breaking timing-critical NMI transfers.

---

## 5. New PCB — Data Bus Pin Assignment

The key insight: **lower nibble A0–A3 is already optimal on Nano Every** (all on PORTD).
For the upper nibble, A4, A5, D6, D3 are all on **PORTF** (bits 2–5):

| Data bus bit | New Arduino pin | ATmega4809 | PORTF/PORTD bit |
|--------------|-----------------|-----------|-----------------|
| D[0] | A3 (D17) | PD0 | PORTD bit 0 |
| D[1] | A2 (D16) | PD1 | PORTD bit 1 |
| D[2] | A1 (D15) | PD2 | PORTD bit 2 |
| D[3] | A0 (D14) | PD3 | PORTD bit 3 |
| D[4] | A4 (D18) | PF2 | PORTF bit 2 |
| D[5] | A5 (D19) | PF3 | PORTF bit 3 |
| D[6] | D6 | PF4 | PORTF bit 4 |
| D[7] | D3 | PF5 | PORTF bit 5 |

**Lower nibble (A0–A3) physical pins are UNCHANGED from the current PCB.**
Only the upper nibble changes from D4–D7 → D3, D6, A4, A5.

New `SetPage()` in C++:
```cpp
// ATmega4809: lower nibble on PORTD[3:0], upper nibble on PORTF[5:2]
PORTD.OUT = (PORTD.OUT & 0xF0) | (value & 0x0F);
PORTF.OUT = (PORTF.OUT & 0xC3) | ((value & 0xF0) >> 2);
```
Same number of register writes as the current 328P code (2). At 20 MHz vs 16 MHz,
each write is 25% faster. The NMI tight-loop in `CartApi.cpp` stays at 2 port writes.

### Remaining signal reassignments

D3 is now a data bus pin, so EXROM must move. Suggested new pin allocation:

| Signal | Current (328P) | New (4809) | Notes |
|--------|---------------|-----------|-------|
| IO2 (INT0) | D2 (PA0) | D2 (PA0) | **unchanged** |
| /NMI | D8 (PB0→PE3) | D8 (PE3) | **unchanged** |
| /RESET →C64 | D9 (PB0) | D9 (PB0) | **unchanged** |
| SD /CS | D10 (PB1) | D10 (PB1) | **unchanged** |
| MOSI/MISO/SCK | D11–D13 | D11–D13 | **unchanged** |
| /EXROM | D3 → data bus | D5 (PB2) | moved |
| SEL (C64 /RST) | A4 → data bus | D4 (PC6) | moved |
| STATUS LED | A5 → data bus | D7 (PA1) | moved |
| SRAM /OE | — | D0 (PC5) | new |
| SRAM /WE + counter CLK/CLR | — | D1 (PC4), D7¹ | new |

¹ Exact assignment TBD during PCB layout — depends on available pins after routing.

---

## 6. SRAM Chip Selection

**Target: 8 KB SRAM** — ROML space ($8000–$9FFF) requires 13 address bits (A0–A12).
The IRQ loader binary is 256 bytes; a full 8 KB image is padded with the loader
replicated or zeroed at unused positions (same logic as `create_eprom_loader()`).

**Recommended: 6264 (8 KB × 8-bit SRAM)**

| Property | Value |
|----------|-------|
| Capacity | 8 KB (exactly matches ROML) |
| Package | DIP-28 |
| Supply | 5 V |
| Access time | 55–100 ns (well within C64's ~250 ns window) |
| /OE, /WE, /CE | standard active-low controls |
| Examples | Alliance AS6C6264, ISSI IS62C256 (32K), HM6264 |

**Pinout compatibility with AT27C512:**

| Pin | AT27C512 | 6264 | Compatible? |
|-----|----------|------|-------------|
| 1 | A15 | NC | ✓ (don't connect) |
| 14 | GND | GND | ✓ |
| 15 | D3 | D3 | ✓ |
| 20 | /CE | /CE | ✓ |
| 22 | /OE | /OE | ✓ |
| 27 | A14 | /WE | ✗ — new connection needed |
| 26 | A13 | CS2 | ✗ — tie to VCC (always enabled) |
| 28 | VCC | VCC | ✓ |

The 6264 is close to the AT27C512 in pinout. Key differences are pins 26 and 27.
On the new PCB:
- Pin 26 (CS2): connect to VCC → always enabled
- Pin 27 (/WE): connect to Arduino output pin (write enable during SRAM init)

---

## 7. Address Counter for SRAM Initialization

The Arduino does not have enough free GPIO to drive 13 SRAM address lines directly
(18 pins are already used for C64 interface + SPI + SD). A **binary address counter**
solves this with only 3 extra Arduino pins:

```
Arduino CLR ──→ [74HC4040 12-bit counter] ──→ SRAM A0–A11
Arduino CLK ──→    + 1 bit direct (A12)   ──→ SRAM A12
Arduino /BUF_OE → [74HC244 octal buffer]
                  (tri-state during normal C64 operation)
```

**Boot write sequence:**
1. Assert CLR → counter = 0, assert /BUF_OE LOW (outputs enabled)
2. For each byte in the 8 KB ROM image:
   a. Write data bits via Arduino data bus pins
   b. Assert /WE LOW → HIGH (10 ns pulse — one Arduino instruction at 20 MHz = 50 ns ✓)
   c. Assert CLK HIGH → LOW (counter increments)
3. De-assert CLR (counter stays at 8192)
4. Assert /BUF_OE HIGH → counter outputs tri-stated
5. C64 address bus now drives SRAM address lines exclusively
6. Release C64 /RESET

**Write speed:** At 20 MHz, writing 8192 bytes takes approximately 8192 × ~5 cycles
= ~41,000 cycles = ~2 ms. Well within the C64 boot time.

**Normal operation:** Counter outputs are tri-stated (/BUF_OE HIGH). The C64 address
bus lines (routed to the same SRAM address pins via the PCB) drive the SRAM freely.
The counter IC does not interfere.

---

## 8. Software Changes Required

### High impact

| File | Change | Risk |
|------|--------|------|
| `CartInterface.cpp` | `SetAddressPinsOutput()`: replace `DDRD/DDRC` with `PORTD.DIR`, `PORTF.DIR` | Medium |
| `CartInterface.cpp` | `SetPage()`: replace 2× 328P port writes with 2× 4809 port writes | **High** — timing critical |
| `CartInterface.cpp` | NMI/RESET pulse: replace `PORTD/PORTB _BV()` with `PORTE.OUT`, `PORTB.OUT` | Medium |
| `CartApi.cpp` | All `PORTD/PORTC` register accesses (8 occurrences) → new port mapping | **High** — timing critical |
| `CartApi.cpp` | `PIND & 0x04` (IO2 read) → `PORTA.IN & PIN0_bm` | Medium |
| `EasySD.ino` | Add SRAM init at boot (write 8 KB image, control /WE, CLK, CLR) | Medium |
| `EasySD.ino` | Add SRAM /OE management: disable before NMI transfer, re-enable after | Medium |
| `FlashLib.h` build | Store full 8 KB SRAM image in PROGMEM (currently only 245 B stub) | Low — build change |

### Low impact

| File | Change |
|------|--------|
| `CartInterface.h` | Update pin definitions (EXROM → D5, SEL → D4, LED → D7, new: SRAM_OE, ADDR_CLK, ADDR_CLR) |
| `CartApi.cpp` | Internal EEPROM: 256 B on 4809 vs 1 KB on 328P — 66 bytes used, no change needed |
| `build.py` | Flash target: `arduino.megaavr.nona4809` instead of `arduino.avr.nano` |

### ATmega4809 register syntax difference

The ATmega4809 uses struct-based port access, not simple registers:

| ATmega328P | ATmega4809 |
|-----------|-----------|
| `PORTD = value` | `PORTD.OUT = value` |
| `DDRD = mask` | `PORTD.DIR = mask` |
| `PIND` | `PORTD.IN` |
| `PORTD &= ~_BV(PD3)` | `PORTD.OUTCLR = PIN3_bm` |
| `PORTD \|= _BV(PD3)` | `PORTD.OUTSET = PIN3_bm` |

The `#ifdef __AVR__` guards in `CartInterface.cpp` remain valid — ATmega4809 is also
AVR architecture. A new `#ifdef ARDUINO_ARCH_MEGAAVR` guard would separate 4809 vs 328P
code paths.

---

## 9. Flash Budget on Nano Every

| Component | Size estimate |
|-----------|--------------|
| Arduino firmware (current release) | ~22.7 KB |
| 8 KB SRAM image in PROGMEM | +8.0 KB |
| Growth from new features (SRAM init, /OE control) | ~0.5 KB |
| **Total estimated** | **~31.2 KB** |
| **Available on Nano Every** | **48 KB** |
| **Headroom** | **~16.8 KB** |

This is a dramatic improvement over the current 472-byte debug build margin.

---

## 10. Component Summary for New PCB

| Component | Notes |
|-----------|-------|
| Arduino Nano Every (ATmega4809) | Headers version recommended for socketing |
| 6264 SRAM (8 KB, 5 V, DIP-28) | e.g. Alliance AS6C6264-55PCN |
| MicroSD adapter, 5 V with level shifter | e.g. Adafruit ADA254 or equivalent |
| 74HC4040 (12-bit binary counter, DIP-16) | SRAM address A0–A11 during boot |
| 74HC244 (octal tri-state buffer, DIP-20) | Tri-state counter outputs during C64 operation |
| 100 µF electrolytic cap | SD VCC/GND |
| 100 nF ceramic caps (×3–4) | Decoupling: Arduino, SRAM, SD module |
| 220 Ω resistor + 5 mm LED | Status indicator |
| Tactile pushbutton | Menu/Reset |

---

## 11. Open Questions and Risks

| Question | Impact | Notes |
|----------|--------|-------|
| NMI transfer timing at 20 MHz | High | Current code tuned for 16 MHz. Pulse widths and inter-NMI delays must be re-measured and adjusted. |
| IO2 streaming ISR latency | High | Current margin is ~0.5 µs (PAL). At 20 MHz the ISR fires faster — may be fine, but must be verified. |
| PORTD.OUT / PORTF.OUT write latency | High | Must confirm 2 port writes are within the NMI byte-delivery window. |
| CvdPlayer READCART_MODULATED | Medium | Uses both $DF00 and $80AB in tight sequence. SRAM /OE must be managed correctly. |
| 74HC4040 ripple counter glitches | Low | Ripple counters have transient glitch states during count. Use synchronous 74HC163 if glitches cause SRAM write errors (write only when count is stable). |
| A4/A5 used for I2C on Nano Every | Low | Reassigning A4/A5 to the data bus removes hardware I2C capability. Not used by EasySD. |
| EXROM signal on PB2 (D5) | Low | D5 is PWM-capable; no conflict for a simple digital output. |

---

## 12. Summary

This upgrade is **technically sound and strongly recommended** for the next PCB revision.
The main benefits are:

- **3× more SRAM** — eliminates the tight memory pressure that constrains every feature
- **No external EEPROM programmer** — boot ROM is stored in Arduino flash, written to SRAM at boot
- **Clean bus management** — SRAM /OE replaces brute-force data bus override
- **50% more flash** — debug builds fit comfortably; new features have room to grow
- **25% faster CPU** — streaming and NMI throughput benefit from 20 MHz
- **Lower nibble pin assignment unchanged** — A0–A3 stay on the same PCB traces

The software migration is non-trivial (port register rewrite + timing validation) but
well-contained within `CartInterface.cpp` and `CartApi.cpp`. The largest risk is NMI
and IO2 timing recalibration, which requires hardware testing with the real C64.
