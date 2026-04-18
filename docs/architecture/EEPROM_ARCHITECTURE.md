# EasySD EEPROM Architecture

Two separate memory devices in the EasySD project are both called "EEPROM" in everyday speech. This document defines the canonical terminology.

---

## Terminology

| Concept | Canonical Name | Physical Device |
|---------|---------------|-----------------|
| ATmega328P built-in EEPROM | **MCU internal EEPROM** | On-chip, 1 KB, read/write at runtime |
| Cartridge PCB memory chip | **cartridge ROML chip** | External IC (AT27C512R or M27C512), 64 KB, programmed externally |

---

## 1. Cartridge ROML Chip

The external ROM chip on the PCB. The C64 sees it at `$8000–$9FFF` (ROML space, 8K cart mode).

**Role:** Holds the loader image executed by the C64 from cartridge ROM. Also serves as the data path for NMI byte transfer via `SetPage()`.

**How SetPage works:**

```cpp
void CartInterface::SetPage(unsigned char value) {
    PORTD = (PORTD & 0x0F) | (value & 0xF0);   // A12–A15
    PORTC = (PORTC & 0xF0) | (value & 0x0F);   // A8–A11
}
```

`SetPage(n)` drives the upper 8 address bits. The chip is pre-programmed so that byte at address `n*256 + 0xAB` equals `n`. Therefore `SetPage(n)` + `LDA $80AB` on the C64 returns `n`.

**EXROM control:**
- `EnableCartridge()` — EXROM LOW, ROML visible, data bus pins set to OUTPUT
- `DisableCartridge()` — EXROM HIGH, ROML hidden
- `EnableExromOnly()` — EXROM LOW but data bus pins remain INPUT (used during CBM80 detection)

**Build artifact:** `build/IRQLoaderRom.bin` (64 KB image, flash with external programmer).

The Arduino cannot write to this chip at runtime.

---

## 2. MCU Internal EEPROM

The ATmega328P's built-in 1 KB EEPROM, readable and writable at runtime by firmware.

**Current status:** Not in active use. Last-directory persistence was removed; startup always begins from root. All 1 KB is available for future use.

**C64-accessible commands:**

| Command | ID | Description |
|---------|----|-------------|
| `COMMAND_SEEK_EEPROM` | 16 | Set read/write pointer (10-bit address, wraps at 1024) |
| `COMMAND_READ_EEPROM` | 15 | Read byte at pointer, auto-increment |
| `COMMAND_WRITE_EEPROM` | 17 | Write byte at pointer, auto-increment |

C64 side: `PROT_SeekEeprom` (A=high, X=low), `PROT_ReadEeprom` (→ A), `PROT_WriteEeprom` (X=value).

---

## Summary

| | Cartridge ROML Chip | MCU Internal EEPROM |
|---|---|---|
| Size | 64 KB | 1 KB |
| Arduino can write | No | Yes |
| Purpose | Loader ROM + NMI data transfer | Persistent settings (currently unused) |
| C64 access | `LDA $80AB` via SetPage | `PROT_ReadEeprom` / `PROT_WriteEeprom` |
| Build artifact | `build/IRQLoaderRom.bin` | N/A |
