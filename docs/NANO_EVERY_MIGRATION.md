# EasySD — ATmega328P to ATmega4809 (Nano Every) Migration Guide

**Status:** Planning / Pre-implementation  
**Date:** 2026-04-19  
**Supersedes:** `docs/archive/NANO_EVERY_UPGRADE.md` (2026-03-11 design study, included SRAM chip proposal)

This document covers the **MCU-only swap** from Arduino Nano (ATmega328P) to Arduino Nano
Every (ATmega4809) — no additional SRAM chip, no address counter, no EPROM replacement.
The goal is a firmware-only migration with minimal PCB trace changes.

---

## 1. Why Migrate

| Resource | ATmega328P (Nano) | ATmega4809 (Every) | Gain |
|----------|-------------------|---------------------|------|
| **SRAM** | 2 KB (~530 B free) | **6 KB** (~4530 B free) | **+200%** |
| **Flash** | 30.7 KB (75% used, 23.2 KB) | **48 KB** (~46 KB usable) | **+50%** |
| **Clock** | 16 MHz (external) | 20 MHz (internal osc, 16 MHz default) | +25% |
| **EEPROM** | 1 KB | 256 B | −75% (not used) |
| **Ext. interrupts** | INT0/INT1 only (D2, D3) | **Any pin** | Much more flexible |
| **Programming** | ISP (SPI, 6-pin header) | **UPDI** (single-wire) | Different protocol |

The SRAM tripling is the primary motivation. The current ~530 B free margin makes every
buffer and stack frame a tight squeeze. With 6 KB SRAM, there is room for larger SD read
buffers, deeper directory nesting, and more comfortable stack headroom.

---

## 2. Physical Compatibility

The Nano Every has the **same 30-pin DIP header layout** as the Nano. Same 5V logic levels.
It is a physical drop-in replacement — no socket or mounting changes needed.

**However:** the internal port-to-pin mapping is completely different (see section 4).
The board fits the socket, but the firmware cannot use direct port register access
without remapping.

---

## 3. ATmega4809 Pin Map (Nano Every Form Factor)

Source: official Arduino `pins_arduino.h` for `arduino:megaavr:nona4809`.

| Arduino Pin | ATmega4809 Port | Notes |
|-------------|-----------------|-------|
| D0 | PC5 | Serial TX |
| D1 | PC4 | Serial RX |
| D2 | PA0 | |
| D3 | PF5 | |
| D4 | PC6 | |
| D5 | PB2 | |
| D6 | PF4 | |
| D7 | PA1 | |
| D8 | PE3 | |
| D9 | PB0 | |
| D10 | PB1 | SPI /SS |
| D11 | PE0 | SPI MOSI |
| D12 | PE1 | SPI MISO |
| D13 | PE2 | SPI SCK |
| A0 (D14) | **PD3** | |
| A1 (D15) | **PD2** | |
| A2 (D16) | **PD1** | |
| A3 (D17) | **PD0** | |
| A4 (D18) | PF2 | (I2C SDA on Every) |
| A5 (D19) | PF3 | (I2C SCL on Every) |
| A6 (D20) | **PD4** | Full digital on 4809 (was analog-only on 328P) |
| A7 (D21) | **PD5** | Full digital on 4809 (was analog-only on 328P) |

**Key observation:** A0–A3 + A6–A7 are all on **PORTD** (bits PD0–PD5). With A4 and A5
reassigned, all 8 bits of PORTD (PD0–PD7) could be used as a data bus — but A4/A5 are
on PORTF, not PORTD, so only 6 contiguous PORTD bits are available on headers.

---

## 4. The Port Scatter Problem

The current firmware uses two atomic register writes for the 8-bit data bus:

```cpp
// ATmega328P: D4-D7 = PORTD[7:4], A0-A3 = PORTC[3:0]
PORTD = (PORTD & 0x0F) | (val & 0xF0);   // upper nibble, 1 cycle
PORTC = (PORTC & 0xF0) | (val & 0x0F);   // lower nibble, 1 cycle
```

On the ATmega4809, the current PCB wiring maps D4–D7 to **four different ports**:

| Arduino Pin | 328P Port | 4809 Port | Problem |
|-------------|-----------|-----------|---------|
| D4 | PD4 | **PC6** | scattered |
| D5 | PD5 | **PB2** | scattered |
| D6 | PD6 | **PF4** | scattered |
| D7 | PD7 | **PA1** | scattered |

Writing 4 bits across 4 ports requires 4 read-modify-write sequences (~8–12 cycles)
instead of 1. This would slow down the time-critical NMI and NI streaming loops.

**Solution: reassign data bus pins on the PCB** (see section 5).

---

## 5. Recommended Pin Assignment (New PCB Wiring)

### Strategy: Full 8-bit data bus on PORTD

Move the entire 8-bit data bus to A0–A7, which maps to PORTD on the ATmega4809.
This enables a single atomic write for the full byte:

```cpp
VPORTD.OUT = val;   // all 8 bits, 1 cycle, 62.5 ns @ 16 MHz
```

### Data Bus Mapping

| Data Bit | C64 Signal | Nano Every Pin | 4809 Port Bit | Old Pin (328P) |
|----------|------------|----------------|---------------|----------------|
| D[0] | A8 | **A3** | PD0 | A0 |
| D[1] | A9 | **A2** | PD1 | A1 |
| D[2] | A10 | **A1** | PD2 | A2 |
| D[3] | A11 | **A0** | PD3 | A3 |
| D[4] | A12 | **A4** | PD4 | D4 |
| D[5] | A13 | **A5** | PD5 | D5 |
| D[6] | A14 | **A6** | PD6 | D6 |
| D[7] | A15 | **A7** | PD7 | D7 |

> **Bit order note:** The lower nibble is bit-reversed relative to the Arduino pin
> numbering (A0=PD3, A1=PD2, A2=PD1, A3=PD0). To avoid a software nibble-swap on
> every byte, **wire the PCB so that C64 data bit 0 connects to A3 (PD0), bit 1 to
> A2 (PD1), etc.** Then `VPORTD.OUT = val` writes the correct value with no
> bit manipulation.

### Control Signals

| Signal | Nano Every Pin | 4809 Port | Direction | Notes |
|--------|----------------|-----------|-----------|-------|
| EXROM | **D2** | PA0 | Output | unchanged |
| IO2 | **D3** | PF5 | Input + INT | unchanged (all pins support INT on 4809) |
| NMI | **D8** | PE3 | Output (OC) | unchanged |
| RESET | **D9** | PB0 | Output | unchanged |
| SD /CS | **D10** | PB1 | Output | unchanged |
| SPI MOSI | **D11** | PE0 | Output | unchanged |
| SPI MISO | **D12** | PE1 | Input | unchanged |
| SPI SCK | **D13** | PE2 | Output | unchanged |
| PHI2 | **D5** | PB2 | Input | **moved from A4** |
| SEL | **D6** | PF4 | Input + pullup | **moved from A6** |

### What Changes on the PCB

```
Signal          Old Pin (328P)    New Pin (4809)    Change?
─────────────────────────────────────────────────────────────
Data D[0]       A0                A3                MOVED (bit-reversal)
Data D[1]       A1                A2                MOVED (bit-reversal)
Data D[2]       A2                A1                MOVED (bit-reversal)
Data D[3]       A3                A0                MOVED (bit-reversal)
Data D[4]       D4                A4                MOVED
Data D[5]       D5                A5                MOVED
Data D[6]       D6                A6                MOVED
Data D[7]       D7                A7                MOVED
PHI2            A4                D5                MOVED
SEL button      A6                D6                MOVED
EXROM           D2                D2                same
IO2             D3                D3                same
NMI             D8                D8                same
RESET           D9                D9                same
SD CS           D10               D10               same
SPI (3 lines)   D11-D13           D11-D13           same
Serial TX/RX    D0-D1             D0-D1             same
```

**Total: 10 traces change, 10 traces stay.**

### Freed Pins

D4, D5, D7 become available. D4 (PC6) and D7 (PA1) are unused. D5 is now PHI2.

---

## 6. Firmware Changes Required

### 6.1 Port Register Rewrite

The ATmega4809 uses struct-based port access:

| ATmega328P | ATmega4809 | VPORT (single-cycle) |
|-----------|-----------|----------------------|
| `PORTD = val` | `PORTD.OUT = val` | `VPORTD.OUT = val` |
| `DDRD = mask` | `PORTD.DIR = mask` | `VPORTD.DIR = mask` |
| `PIND` | `PORTD.IN` | `VPORTD.IN` |
| `PORTD \|= _BV(PD2)` | `PORTA.OUTSET = PIN0_bm` | `VPORTA.OUT \|= PIN0_bm` |
| `PORTD &= ~_BV(PD2)` | `PORTA.OUTCLR = PIN0_bm` | `VPORTA.OUT &= ~PIN0_bm` |

### 6.2 File-by-File Change List

**CartInterface.h** — Pin definitions:
```cpp
// New pin assignments for ATmega4809
#define IO2   3    // D3 → PF5 (unchanged physical pin)
#define EXROM 2    // D2 → PA0 (unchanged physical pin)
#define NMI   8    // D8 → PE3 (unchanged physical pin)
#define RESET 9    // D9 → PB0 (unchanged physical pin)
#define PHI2  5    // D5 → PB2 (MOVED from A4)
#define SEL   6    // D6 → PF4 (MOVED from A6, now digital)
```

SEL changes from `analogRead()` to `digitalRead()` with external 10k pull-up:
```cpp
inline bool selRead() { return digitalRead(SEL) != LOW; }
```

**CartInterface.cpp** — Data bus operations (~15 lines):
```cpp
// SetPage: single VPORT write replaces two PORT writes
void CartInterface::SetPage(unsigned char value) {
    VPORTD.OUT = value;
}

// SetAddressPinsOutput: single DIR write
void CartInterface::SetAddressPinsOutput() {
    VPORTD.DIR = 0xFF;
}

// tristateDataBus: clear outputs then switch to input
void tristateDataBus() {
    VPORTD.OUT = 0x00;
    VPORTD.DIR = 0x00;
}
```

EXROM control (D2 = PA0):
```cpp
// EnableCartridge:
VPORTA.OUT &= ~PIN0_bm;   // EXROM LOW (was: PORTD &= ~_BV(PD2))

// DisableCartridge:
VPORTA.OUT |= PIN0_bm;    // EXROM HIGH (was: PORTD |= _BV(PD2))
```

NMI (D8 = PE3) and RESET (D9 = PB0):
```cpp
void CartInterface::NmiLow() {
    VPORTE.OUT &= ~PIN3_bm;
    VPORTE.DIR |= PIN3_bm;
}
void CartInterface::NmiHigh() {
    VPORTE.DIR &= ~PIN3_bm;   // input (open-collector release)
    VPORTE.OUT |= PIN3_bm;    // internal pull-up
}
void CartInterface::ResetLow() {
    VPORTB.OUT &= ~PIN0_bm;
    VPORTB.DIR |= PIN0_bm;
}
void CartInterface::ResetHigh() {
    VPORTB.OUT |= PIN0_bm;
    VPORTB.DIR |= PIN0_bm;
}
```

**CartApi.cpp** — Streaming loops (~15 lines):

NI streaming (the tightest loop):
```cpp
// Old (328P):
// PORTD = portDVal | (val & 0xF0);
// PORTC = portCVal | (val & 0x0F);

// New (4809): single write, full byte
VPORTD.OUT = sharedBuf.ni[bufferIndex];
```

IO2 edge detection (IO2 = D3 = PF5):
```cpp
// Old: while (PIND & 0x08)
// New:
while (VPORTF.IN & PIN5_bm) { ... }
```

**CartApi.cpp** — Timer interrupt disable/enable:
```cpp
// Old (328P): TIMSK2 = 0 / TIMSK2 = 0x02
// New (4809): disable TCB0 (millis timer on megaAVR core)
TCB0.INTCTRL = 0;                  // disable
TCB0.INTCTRL = TCB_CAPT_bm;       // re-enable
```

**EasySD.ino** — PHI2 and SEL:
```cpp
// PHI2 moves from A4 to D5 — digitalRead(PHI2) still works, no code change needed
// SEL moves from A6 to D6 — analogRead() replaced by digitalRead() in CartInterface.h
```

### 6.3 SdFat Library

The bundled SdFat copy uses raw ATmega328P SPI registers (`SPCR`, `SPDR`, `SPSR`).
These do not exist on the ATmega4809.

**Action:** Update to upstream SdFat 2.x from [greiman/SdFat](https://github.com/greiman/SdFat).
Modern SdFat 2.x has built-in megaAVR 0-series support through its hardware abstraction layer.
No custom SPI porting needed — just replace the library.

### 6.4 Build System (Tools/build.py)

| Setting | Current (328P) | New (4809) |
|---------|----------------|------------|
| Board FQBN | `arduino:avr:nano` | `arduino:megaavr:nona4809` |
| Core package | `arduino:avr` | `arduino:megaavr` |
| Upload protocol | ISP (USBtinyISP) | USB serial (SAMD11 UPDI bridge) |
| Upload command | `arduino-cli upload -P usbtinyisp` | `arduino-cli upload -p COMx` |
| ISP SCK flags | `--isp-sck 2` | N/A (UPDI has no SCK setting) |

**Alternative core:** [MegaCoreX](https://github.com/MCUdude/MegaCoreX) (MCUdude) is
recommended over the official Arduino megaAVR core. Benefits:
- Does not break `millis()`/`delay()` when TCA0 timer prescaler is modified
- No false register emulation layer (forces clean porting)
- Supports bare ATmega4809 chips with UPDI header (future production path)

### 6.5 ISR Changes

On the ATmega4809, interrupt flags must be **manually cleared** inside ISRs:

```cpp
// ATmega328P: flags auto-clear when ISR executes — nothing to do
// ATmega4809: must clear explicitly
ISR(PORTF_PORT_vect) {
    PORTF.INTFLAGS = PIN5_bm;   // clear IO2 interrupt flag
    // ... handler code ...
}
```

If using `attachInterrupt()`, the Arduino core handles flag clearing automatically.
Only raw ISR vectors need the manual clear.

---

## 7. UPDI Programming (Replaces ISP)

The Nano Every has an on-board ATSAMD11 that acts as a USB-to-UPDI bridge. Upload
goes through USB serial — the SAMD11 converts to UPDI protocol.

**This is NOT a bootloader on the ATmega4809 itself.** UPDI holds the chip in reset
during programming — there is no startup delay window like a traditional bootloader.
The EasySD cold-boot sequence (IRQHack64-style: AVR does not hold C64 `/RESET`,
the C64 cold-boots from its own RC) is unaffected.

| Property | ISP (328P) | UPDI (4809) |
|----------|------------|-------------|
| Programmer | USBtinyISP (external) | On-board SAMD11 (USB) |
| Connection | 6-pin ISP header | USB cable |
| Startup delay | None (no bootloader) | None (UPDI is not a bootloader) |
| Speed | ~10 sec (500 kHz SPI) | ~5 sec (USB serial) |
| Brick recovery | ISP SCK slowdown (10 kHz) | UPDI always works (single-wire) |

For bare ATmega4809 chips (future production PCB), use a SerialUPDI programmer
(any USB-serial adapter with a 4.7k resistor) or a dedicated UPDI tool.

---

## 8. Timing Analysis

### NMI Transfer Timing

Current byte delivery window (328P @ 16 MHz):
- `SetPage()`: 2 port writes = ~2 cycles = **125 ns**
- `delayMicroseconds(10)`: NMI LOW pulse = 10 us
- `delayMicroseconds(50)`: inter-byte wait = 50 us

With the PORTD-only pin assignment (4809 @ 16 MHz):
- `SetPage()`: **1 VPORT write = 1 cycle = 62.5 ns** (faster than 328P!)
- `delayMicroseconds()` timing: identical or better at 20 MHz

**Verdict:** NMI transfers will be **faster**, not slower.

### NI Streaming (CVD Player — Tightest Loop)

The NI streaming loop waits for IO2 edges from the C64 (~1 MHz clock = ~1000 ns
between edges). The data must be placed on the bus before the next edge.

| Operation | 328P (2 port writes) | 4809 (1 VPORT write) |
|-----------|---------------------|----------------------|
| Data bus write | ~125 ns | **~62.5 ns** |
| IO2 edge read | ~62.5 ns (PIND) | ~62.5 ns (VPORTF.IN) |
| Margin per edge | ~812 ns | **~875 ns** |

**Verdict:** More margin than before. If 20 MHz is used, margin increases further.

### IO2 ISR Streaming (WAV Player)

The IO2 interrupt fires on each C64 access to $DF00. ISR latency on ATmega4809 is
~5–7 cycles (similar to 328P). The `VPORTD.OUT = val` single-write simplifies the
ISR body, reducing total ISR execution time.

**Verdict:** Should be equivalent or better.

---

## 9. Migration Checklist

### Pre-migration

- [ ] Acquire Arduino Nano Every (headers version for socketing)
- [ ] Update SdFat to upstream 2.x
- [ ] Verify SdFat compiles for `arduino:megaavr:nona4809`
- [ ] Design/order new PCB with reassigned data bus traces (section 5)

### Firmware port

- [ ] Update `CartInterface.h` pin definitions
- [ ] Rewrite `CartInterface.cpp` port register access (~15 lines)
- [ ] Rewrite `CartApi.cpp` port register access (~15 lines)
- [ ] Replace TIMSK2 with TCB0.INTCTRL
- [ ] Update `selRead()` to `digitalRead()`
- [ ] Add ISR interrupt flag clearing if using raw ISR vectors
- [ ] Update `build.py` board target and upload commands

### Validation

- [ ] Compile succeeds with no warnings
- [ ] Serial debug output works (57600 baud)
- [ ] SD card init + file listing works
- [ ] Real C64 menu navigation works with Arduino serial logging enabled
- [ ] HWTest plugin passes on real C64 hardware
- [ ] Cold boot releases C64 to BASIC
- [ ] SEL button triggers menu load
- [ ] PRG loading works (small + large + P2TK path)
- [ ] NMI byte transfer timing verified with logic analyzer
- [ ] IO2 streaming timing verified (CVD, WAV if applicable)
- [ ] All plugins tested on real C64

---

## 10. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| NMI/NI timing drift at different clock | Medium | Verify with logic analyzer; 20 MHz gives 25% more headroom |
| SdFat upstream incompatibility | Low | SdFat 2.x officially supports megaAVR 0-series |
| `millis()` broken by timer changes | Medium | Use MegaCoreX instead of official Arduino core |
| SEL button behavior change (analog→digital) | Low | External 10k pull-up already present; threshold logic simplifies |
| Unknown UPDI quirks | Low | UPDI is well-tested; no startup delay concerns |
| PCB layout errors in trace reassignment | Medium | Double-check with continuity tester before first power-on |

---

## 11. Future Considerations

- **20 MHz operation:** The ATmega4809 can run at 20 MHz (internal oscillator).
  This gives 25% more CPU time per C64 clock cycle. Can be enabled later if
  16 MHz proves tight for any timing path.
- **SRAM chip upgrade:** The original `NANO_EVERY_UPGRADE.md` proposed replacing
  the cartridge ROML EPROM with a 6264 SRAM chip written by the Arduino at boot.
  This remains a valid future enhancement but is **not required** for the MCU swap.
- **Production PCB:** A bare ATmega4809 TQFP-48 on a custom PCB with UPDI header
  is the clean production path. MegaCoreX supports this configuration.
