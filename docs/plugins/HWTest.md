# EasySD HWTest Plugin — Hardware Signal Diagnostic

**Document Type:** Reference / User Guide
**Version:** 1.0
**Created:** 2026-04-05
**Status:** Current

---

## 1. Purpose

HWTest verifies signal integrity between the C64 expansion port and the Arduino.
It runs automatically at startup (no keypress required) and displays each test result
on the menu status line (row 24). Auto-exits to the menu after ~1.5 seconds.

---

## 2. What Is Tested

| Test | Signal(s) verified | Method |
|------|-------------------|--------|
| ROML / EXROM | /EXROM wire, EEPROM, ROML address bus | Implicit — if the plugin loads and runs, these are correct |
| SW Serial (C64→Arduino) | /IO2 (D3/INT1), bit timing decode | `CMD_HWTEST` (32) must be received and acknowledged by Arduino |
| NMI + Data Bus (D0–D7) | /NMI (D8), data bits D4–D7 + A0–A3 | Arduino sends 10 known bit-patterns via NMI; C64 verifies each |

Tests not covered by this plugin: /RESET (D9), PHI2 (A4), IRQ (A5), IO2 streaming ($DF00).

---

## 3. Status Line Display Sequence

```
"   EASYSD HW TEST..."   white  → ~0.4s pause
"   ROML: OK"            green  → ~0.3s pause
"   NMI+DBUS TESTING..."  white  → Arduino processes (~15ms)
"   NMI+DBUS: OK"        green  → ~1.5s → auto-exit to menu
```

On failure:
```
"   FAIL: NO ARDUINO RESPONSE"   red  → SW serial or /EXROM broken
"   FAIL: DATABUS ERROR"         red  → data bus bit mismatch
```

Colors: white = $01, green = $05, red = $02.

---

## 4. SD Card Setup

1. Copy `EasySD/build/plugins/hwtplugin.prg` → `/PLUGINS/HWTPLUGIN.PRG` on SD card.
2. Create an empty file `HWTEST.HWT` anywhere on the SD card (e.g. in root).
3. In the EasySD menu, navigate to `HWTEST.HWT` and press Enter.

The menu resolves `.HWT` → `/PLUGINS/HWTPLUGIN.PRG` automatically.

---

## 5. How It Works

### C64 Side (`EasySD/Plugins/HWTest/HWTest.s`)

1. Saves VIC registers and processor port ($01).
2. Shows "EASYSD HW TEST..." on the status line.
3. Shows "ROML: OK" (implicit — code is running).
4. Sets up the NMI handler: `SOFTNMIVECTOR` ($0318/$0319) → `CARTRIDGENMIHANDLERX1`
   at $80xx (EEPROM), `ZP_IRQ_API_DATA_*` → `TEST_BUFFER` (256 bytes after plugin code).
5. Sends `CMD_HWTEST` (32) via software serial (`PROT_StartTalking` + `PROT_Send`).
6. Waits for `SUCCESSFUL` ($80) response via `PROT_WaitProcessing`.
7. Polls `ZP_IRQ_STATE_WAITHANDLE` ($64) until NMI handler signals completion.
8. Verifies `TEST_BUFFER[0..9]` against `HWT_PATTERNS`: XORs each byte; ORs mismatches
   into `HWT_RESULT`. Any non-zero result → data bus error.
9. Displays result, waits 90 frames (~1.5s PAL), restores state, exits to menu.

### Arduino Side (`CartApi.cpp:HandleHwTest`)

```cpp
void CartApi::HandleHwTest() {
    static const uint8_t pat[10] = {
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x55, 0xAA
    };
    HandleResponse(SUCCESSFUL, 1);   // 1ms: C64 reads response, sets up NMI handler
    noInterrupts();
    for (uint8_t i = 0; i < 10; i++)
        cartInterface.TransmitByteFastStd(pat[i]);
    for (uint16_t i = 10; i < 256; i++)
        cartInterface.TransmitByteFastStd(0x00);
    interrupts();
    cartInterface.SoftStartListening();
}
```

Uses `TransmitByteFastStd` (50µs inter-byte delay) — matches the X1 NMI handler timing.

### Test Patterns

| Index | Pattern | Tests |
|-------|---------|-------|
| 0 | `$01` | D0 only |
| 1 | `$02` | D1 only |
| 2 | `$04` | D2 only |
| 3 | `$08` | D3 only |
| 4 | `$10` | D4 only |
| 5 | `$20` | D5 only |
| 6 | `$40` | D6 only |
| 7 | `$80` | D7 only |
| 8 | `$55` | alternating 0101... |
| 9 | `$AA` | alternating 1010... |

The XOR of received vs expected is OR-accumulated into `HWT_RESULT`. A non-zero
`HWT_RESULT` indicates which bits are stuck or crossed.

---

## 6. Zero Page Usage

| Address | Name | Usage |
|---------|------|-------|
| `$8B/$8C` | tmp ptr | `HWT_STATUSLINE` — string pointer (free per CartZpMap.inc) |
| `$64` | `ZP_IRQ_STATE_WAITHANDLE` | NMI done flag — polled by `#WAITFOR` |
| `$6B` | `ZP_IRQ_API_DATA_LENGTH` | NMI page count (= 1) |
| `$6C/$6D` | `ZP_IRQ_API_DATA_LO/HI` | NMI target buffer address |

---

## 7. Plugin Layout

```
$C000  JMP MAIN
$C003  MAIN — plugin entry point
       Phase 0: announce
       Phase 1: ROML implicit OK
       Phase 2: NMI+DBUS test
       Phase 3: verify + result display
       _done: WAITFRAMES(90) → RESTORESTATE → PROT_DisableDisplay → PROT_ExitToMenu
       HWT_STATUSLINE — ~60 bytes, writes $07C0+Y / $DBC0+Y (Y=3..36)
       WAITFRAMES — raster-synced frame delay (polls $D012)
       SAVESTATE / RESTORESTATE — saves $01, $DD00, $D011, $D016, $D018, $D020, $D021
       String data, HWT_PATTERNS, plugin variables
       CartLibStream.s (full CartLib chain)
       DebugStrings.s
TEST_BUFFER  ; label only — 256 bytes of runtime RAM follow
```

---

## 8. Build

```bash
python Tools/build.py plugins
# Output: EasySD/build/plugins/hwtplugin.prg
```

HWTest is entry `("Plugins/HWTest", "HWTest.s", "hwtplugin")` in `PLUGIN_MATRIX` in `Tools/build.py`.
