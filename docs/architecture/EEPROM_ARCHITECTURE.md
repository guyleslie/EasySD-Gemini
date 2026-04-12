# EasySD — EEPROM Architecture & Terminology

There are two completely separate memory chips in the EasySD project that are
both called "EEPROM" in everyday speech. This page defines the canonical
terminology used throughout the source code and documents both chips' roles.

---

## Terminology (canonical names used in source comments)

| Concept | Canonical name in comments | Physical device |
|---------|---------------------------|-----------------|
| ATmega328P built-in EEPROM | **MCU internal EEPROM** | On-chip, 1 KB, read/write at runtime via `EEPROM.h` / `avr/eeprom.h` |
| Cartridge PCB memory chip | **cartridge ROML chip** | External IC on PCB: AT27C512R-45PU or M27C512, 64 KB, programmed externally |

Key rule: whenever source code comments mention "MCU internal EEPROM" they
refer to Arduino runtime read/write via `EEPROM.read()` / `EEPROM.write()`.
Whenever comments mention "cartridge ROML chip" they refer to the external
AT27C512R-45PU or M27C512 IC that the C64 sees at `$8000-$9FFF` (ROML).

---

## 1. Cartridge ROML Chip (external, on PCB)

### Supported chip variants

| Variant | Type | Notes |
|---------|------|-------|
| **AT27C512R-45PU** | 64K×8 cartridge ROM device | Supported cartridge ROML chip used in the current PCB/build documentation |
| **M27C512** | 64K×8 EPROM | Compatible cartridge ROML chip option |

Both are pin-compatible and functionally identical at runtime (read-only from
the Arduino's perspective).

### Role

This chip holds the cartridge-side loader image that the C64 executes from cartridge ROM
space (`$8000–$9FFF`, ROML). It also serves as the data source for the NMI transfer path
that uses `SetPage` plus fixed ROML read addresses.

### Hardware connections

| Signal | Direction | Description |
|--------|-----------|-------------|
| `/EXROM` | Arduino → C64 | Controls ROML visibility. LOW = chip enabled, HIGH = chip disabled. Driven by Arduino D2 (`PD2`). |
| `A8–A11` | Arduino → chip | Higher address bits, driven by Arduino analog pins A0–A3 (`PORTC[3:0]`). |
| `A12–A15` | Arduino → chip | Highest address bits, driven by Arduino D4–D7 (`PORTD[7:4]`). |
| `A0–A7` | C64 → chip | Lower address bits, driven by C64 address bus. |
| `D0–D7` | chip → C64 | Data bus, read-only from the Arduino's perspective. |

### EXROM control

```cpp
void CartInterface::EnableCartridge()  { PORTD &= ~_BV(PD2); }  // EXROM LOW  → ROML active
void CartInterface::DisableCartridge() { PORTD |= _BV(PD2);  }  // EXROM HIGH → ROML disabled
```

`EnableExromOnly()` sets EXROM LOW while **leaving data bus pins as INPUT
(tristate)** — required during the CBM80 detection window (~300 ms after
reset) so the cartridge ROML chip can drive the bus without contention.

`EnableCartridge()` additionally sets the data bus pins to OUTPUT, used when
the Arduino itself needs to transmit bytes via NMI.

### SetPage — the streaming mechanism

```cpp
void CartInterface::SetPage(unsigned char value) {
    PORTD = (PORTD & 0x0F) | (value & 0xF0);  // A12–A15
    PORTC = (PORTC & 0xF0) | (value & 0x0F);  // A8–A11
}
```

`SetPage(n)` drives the upper 8 address bits of the chip. The lower 8 bits
come from the C64's own address bus when it reads from ROML.

When the C64 reads `$80AB`:
- Lower address bits = `$AB` = 171 (from C64 address bus)
- Upper address bits = `n` (set by `SetPage(n)`)
- Effective chip address = `n * 256 + 0xAB`

The chip is pre-programmed so that byte at address `n * 256 + 0xAB` equals `n`.
Therefore: **`SetPage(n)` followed by `LDA $80AB` on the C64 returns `n`**.

This is `CARTRIDGE_BANK_VALUE = $80AB` in the C64 assembly source.

### Chip image layout

The current build generates a 64 KB image for the cartridge ROML chip.
It is built from repeated IRQ-loader pages with embedded page-index bytes at
selected offsets. This allows `SetPage()` + fixed read address to transfer an
arbitrary byte value.

Offsets within each page that contain the page index (decimal):

```
171 ($AB), 166 ($A6), 103 ($67), 141 ($8D), 121 ($79),
151 ($97), 146 ($92), 161 ($A1), 156 ($9C), 195 ($C3),
176 ($B0), 255 ($FF)
```

Multiple offsets exist because different parts of the C64 code read from
different addresses within ROML (e.g., `$80AB`, `$80A6`, etc.).

### Write access

**The Arduino cannot write to this chip.** It can only drive address lines
and the `/EXROM` enable signal. The chip must be programmed externally with
a dedicated EEPROM/EPROM programmer before assembly.

### Build artifact

The release build generates the chip image automatically:

```
python Tools/build.py release
→ EasySD/build/IRQLoaderRom.bin   (64 KB, ready to flash to chip)
```

`build.py` function: `create_eprom_loader(irq_bin, eprom_out, eprom_pos)`

Input: `IRQLoader.65s.bin` (IRQ loader binary)
Output: `IRQLoaderRom.bin` (65536 bytes — generated image for the cartridge ROML chip)

---

## 2. MCU Internal EEPROM (ATmega328P, 1 KB)

### Role

The ATmega328P has 1 KB of built-in EEPROM that the Arduino firmware can
read and write at runtime. It is **completely independent** of the cartridge
ROML chip.
Intended use: **persistent user settings** (e.g., last directory, preferences).

### Current status

**Not in use** — last-directory persistence has been removed from the firmware.
The menu always starts from root. All 1 KB of MCU internal EEPROM is available
for future use.

### C64-accessible MCU internal EEPROM commands

The C64 can read and write the MCU internal EEPROM directly via the protocol.
These commands target the ATmega internal EEPROM, **not** the cartridge ROML
chip.

Arduino side (`CartApi.cpp`):

| Function | Command ID | Description |
|----------|-----------|-------------|
| `HandleSeekEeprom()` | `COMMAND_SEEK_EEPROM` (16) | Set read/write pointer (`eepromIndex`) to 10-bit address |
| `HandleReadEeprom()` | `COMMAND_READ_EEPROM` (15) | Read byte at `eepromIndex`, auto-increment |
| `HandleWriteEeprom()` | `COMMAND_WRITE_EEPROM` (17) | Write byte at `eepromIndex`, auto-increment |

Address space: 0–1023 (wraps at 1024). Pointer persists between calls.

```cpp
// MCU internal EEPROM — NOT the cartridge ROML chip
void CartApi::HandleReadEeprom() {
    uint8_t value = EEPROM.read(eepromIndex);
    HandleValueResponse(value);
    IncrementEepromAddress();   // wraps at 1024
}
```

C64 side (`CartLibHi.s`):

| Label | Registers in | Description |
|-------|-------------|-------------|
| `PROT_SeekEeprom` | A = address high (bits 9–8), X = address low (bits 7–0) | Set pointer |
| `PROT_ReadEeprom` | — | Read one byte → returned in A |
| `PROT_WriteEeprom` | X = value | Write one byte |

All three communicate via the standard `PROT_Send` / `PROT_WaitProcessing`
protocol (IO2 software serial, C64 → Arduino).

---

## Summary

| | Cartridge ROML chip (PCB) | MCU internal EEPROM |
|---|---|---|
| Canonical name | "cartridge ROML chip" | "MCU internal EEPROM" |
| Chip variants | AT27C512R-45PU or M27C512 | Built-in ATmega328P |
| Size | 64 KB | 1 KB |
| Arduino write | No (read-only at runtime) | Yes |
| Purpose | IRQ loader ROM + NMI streaming data transfer | Persistent settings (reserved for future use) |
| C64 access | `LDA $80AB` (ROML, via SetPage) | `PROT_ReadEeprom` / `PROT_WriteEeprom` |
| Build artifact | `build/IRQLoaderRom.bin` (flash with programmer) | N/A |
| Currently used | Yes (streaming, WavPlayer, CvdPlayer) | No (last-directory persistence removed; all 1 KB available) |
