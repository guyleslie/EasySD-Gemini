# EasySD — EEPROM Architecture & Terminology

There are two completely separate memory chips in the EasySD project that are
both called "EEPROM" in everyday speech. This page defines the canonical
terminology used throughout the source code and documents both chips' roles.

---

## Terminology (canonical names used in source comments)

| Concept | Canonical name in comments | Physical device |
|---------|---------------------------|-----------------|
| ATmega328P built-in EEPROM | **MCU internal EEPROM** | On-chip, 1 KB, read/write at runtime via `EEPROM.h` / `avr/eeprom.h` |
| Cartridge PCB memory chip | **cartridge ROML chip** | External IC on PCB: Microchip AT28C64B (EEPROM) or ST M27C64A (UV EPROM), 8 KB, programmed externally |

Key rule: whenever source code comments mention "MCU internal EEPROM" they
refer to Arduino runtime read/write via `EEPROM.read()` / `EEPROM.write()`.
Whenever comments mention "cartridge ROML chip" they refer to the external
AT28C64B or M27C64A IC that the C64 sees at `$8000-$9FFF` (ROML).

---

## 1. Cartridge ROML Chip (external, on PCB)

### Supported chip variants

| Variant | Type | Notes |
|---------|------|-------|
| Microchip **AT28C64B** | 8K×8 EEPROM | Most common "modern" type; erased/programmed electrically with a programmer |
| ST Microelectronics **M27C64A** | 8K×8 UV EPROM | Classic windowed EPROM; erased with UV light, programmed with a programmer |

Both are pin-compatible and functionally identical at runtime (read-only from
the Arduino's perspective).

### Role

This chip holds the IRQ loader code that the C64 executes from cartridge ROM
space (`$8000–$9FFF`, ROML). It also serves as the **data transfer medium**
for the NMI streaming protocol (`SetPage` + fixed read address).

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

The 8 KB chip is divided into **32 pages × 256 bytes** (for the IRQ loader
image). Every page contains the same IRQ loader code, but at specific byte
offsets within each page the value equals the page index. This allows
`SetPage()` + fixed read address to transfer an arbitrary byte value.

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

Input: `IRQLoader.65s.bin` (256 bytes — the IRQ loader binary)
Output: `IRQLoaderRom.bin` (65536 bytes — 256 copies, one per page, with
page index embedded at the positions listed above)

---

## 2. MCU Internal EEPROM (ATmega328P, 1 KB)

### Role

The ATmega328P has 1 KB of built-in EEPROM that the Arduino firmware can
read and write at runtime. It is **completely independent** of the cartridge
ROML chip.
Intended use: **persistent user settings** (e.g., last directory, preferences).

### Current status

**In use** — the firmware saves and restores the last-visited directory on boot.

### Last-visited directory persistence (SaveLastDir / RestoreLastDir)

On every successful directory change (`COMMAND_CHANGE_DIR`, GoBack), the
firmware writes the current absolute path to the MCU internal EEPROM
(`SaveLastDir()`).  On boot (`CartApi::Init()`), the saved path is read back
and the firmware navigates there before the C64 menu starts
(`RestoreLastDir()`).

EEPROM layout — **66 bytes total** (2 magic + 64 path buffer):

| Offset | Size | Content |
|--------|------|---------|
| 0 | 1 byte | Magic `0xE5` |
| 1 | 1 byte | Magic `0xD0` |
| 2–65 | ≤64 bytes | Null-terminated absolute path (e.g. `/GAMES/ACTION`) |

Why 66 bytes?  The path buffer is a fixed 64-byte field (max 63 printable
characters + terminating `\0`). Prepending 2 magic bytes for validity
detection gives `2 + 64 = 66`. The remaining ~958 bytes of the 1 KB EEPROM
are currently unused.

`EEPROM.update()` is used (writes only if value changed) to minimise write
cycles (100k endurance limit).

If the magic bytes are absent or the path is invalid, restore is silently
skipped and the menu starts at root — safe for fresh chips and corrupted data.

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
| Chip variants | AT28C64B (EEPROM) or M27C64A (UV EPROM) | Built-in ATmega328P |
| Size | 8 KB | 1 KB |
| Arduino write | No (read-only at runtime) | Yes |
| Purpose | IRQ loader ROM + NMI streaming data transfer | Persistent settings (last-visited dir) |
| C64 access | `LDA $80AB` (ROML, via SetPage) | `PROT_ReadEeprom` / `PROT_WriteEeprom` |
| Build artifact | `build/IRQLoaderRom.bin` (flash with programmer) | N/A |
| Currently used | Yes (streaming, WavPlayer, CvdPlayer) | Yes (last-visited directory, 66 bytes) |
