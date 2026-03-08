# EasySD — EEPROM Architecture

There are two completely separate "EEPROM" concepts in the EasySD project.
This document describes both, their roles, and how they interact.

---

## 1. Physical Cartridge EEPROM Chip (64 KB, on PCB)

### Role

This is the ROM chip soldered onto the cartridge PCB. It holds the IRQ loader
code that the C64 executes from cartridge ROM space (`$8000–$9FFF`, ROML).
It also serves as the **data transfer medium** for the streaming protocol.

### Hardware connections

| Signal | Direction | Description |
|--------|-----------|-------------|
| `/EXROM` | Arduino → C64 | Controls ROML visibility. LOW = chip enabled, HIGH = chip disabled. Driven by Arduino D3 (`PD3`). |
| `A8–A11` | Arduino → chip | Higher address bits, driven by Arduino analog pins A0–A3 (`PORTC[3:0]`). |
| `A12–A15` | Arduino → chip | Highest address bits, driven by Arduino D4–D7 (`PORTD[7:4]`). |
| `A0–A7` | C64 → chip | Lower address bits, driven by C64 address bus. |
| `D0–D7` | chip → C64 | Data bus, read-only from the Arduino's perspective. |

### EXROM control

```cpp
void CartInterface::EnableCartridge()  { PORTD &= ~_BV(PD3); }  // EXROM LOW  → ROML active
void CartInterface::DisableCartridge() { PORTD |= _BV(PD3);  }  // EXROM HIGH → ROML disabled
```

`EnableCartridge()` must be called before any operation that requires the C64
to read from ROML — in particular, **before `HandleStream()` attaches its ISR**,
because WavPlayer's CIA1 Timer A interrupt reads `CARTRIDGE_BANK_VALUE` (`$80AB`)
on every audio sample. If EXROM is HIGH at that point, the C64 reads RAM instead
of the chip → silence.

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

The 64 KB chip is divided into **256 pages × 256 bytes**. Every page contains
the same IRQ loader code, but at specific byte offsets within each page the
value equals the page index. This allows `SetPage()` + fixed read address to
transfer an arbitrary byte value.

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
a dedicated EEPROM programmer before assembly.

### Build artifact

The release build generates the chip image automatically:

```
python Tools/build.py release
→ EasySD/build/IRQLoaderRom.bin   (64 KB, ready to flash to chip)
```

`build.py` function: `create_eprom_loader(irq_bin, eprom_out, eprom_pos)`

Input: `IRQLoader.65s.bin` (256 bytes — the IRQ loader binary)
Output: `IRQLoaderRom.bin` (65536 bytes — 256 copies, one per page, with
page index embedded at the positions listed above)

---

## 2. Arduino Internal EEPROM (1 KB, ATmega328P)

### Role

The ATmega328P has 1 KB of built-in EEPROM that the Arduino firmware can
read and write at runtime. It is independent of the cartridge chip.
Intended use: **persistent user settings** (e.g., last directory, preferences).

### Current status

The API is fully implemented on both sides but **no plugin uses it yet**.

### Arduino side (`CartApi.cpp`)

| Function | Command ID | Description |
|----------|-----------|-------------|
| `HandleSeekEeprom()` | 16 | Set read/write pointer (`eepromIndex`) to 10-bit address |
| `HandleReadEeprom()` | 15 | Read byte at `eepromIndex`, auto-increment |
| `HandleWriteEeprom()` | 17 | Write byte at `eepromIndex`, auto-increment |

Address space: 0–1023 (wraps at 1024). Pointer persists between calls.

```cpp
void CartApi::HandleReadEeprom() {
    uint8_t value = EEPROM.read(eepromIndex);
    HandleValueResponse(value);
    IncrementEepromAddress();          // wraps at 1024
}
```

### C64 side (`CartLibHi.s`)

| Label | Registers in | Description |
|-------|-------------|-------------|
| `IRQ_SeekEeprom` | A = address high (bits 9–8), X = address low (bits 7–0) | Set pointer |
| `IRQ_ReadEeprom` | — | Read one byte → returned in A |
| `IRQ_WriteEeprom` | X = value | Write one byte |

All three communicate via the standard `IRQ_Send` / `IRQ_WaitProcessing`
protocol (IO2 software serial, C64 → Arduino).

### Potential uses

- Save last-visited directory path across power cycles
- Store user preferences (e.g., display options, default plugin)
- Plugin-specific persistent state

---

## Summary

| | Physical chip (PCB) | Arduino internal EEPROM |
|---|---|---|
| Size | 64 KB | 1 KB |
| Arduino write | No (read-only at runtime) | Yes |
| Purpose | IRQ loader ROM + streaming data transfer | Persistent settings storage |
| C64 access | `LDA $80AB` (ROML, via SetPage) | `IRQ_ReadEeprom` / `IRQ_WriteEeprom` |
| Build artifact | `build/IRQLoaderRom.bin` (flash with programmer) | N/A |
| Currently used | Yes (streaming, WavPlayer, CvdPlayer) | No (API ready, unused) |
