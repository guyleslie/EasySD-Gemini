# Cartridge Protocol

EasySD uses two distinct data transfer mechanisms between the Arduino and the C64.
They share hardware signals but operate independently depending on context.

---

## Hardware Overview

### C64 Expansion Port Signals Used

| Signal | Direction | C64 Address / Pin | Arduino Pin | Purpose |
|--------|-----------|-------------------|-------------|---------|
| /IO2   | C64 → Arduino | $DF00–$DFFF active | D3 (INT1) | Transfer trigger (falling edge) |
| ROML   | C64 reads  | $8000–$9FFF       | D4–D7, A0–A3 | Data output (NMI transfer and streaming) |
| /EXROM | Arduino → C64 | Expansion pin 9 | D2 (output) | Controls ROM visibility |
| /NMI   | Arduino → C64 | Expansion pin 28 | D8 (output) | Triggers NMI on C64 |
| MENU button | Local to PCB | Tact switch | A6 (analog input) | Detects short/long MENU button press |
| /RESET | Arduino → C64 | Expansion pin 30 | D9 (output) | Triggers C64 reset |
| IRQ    | — | — | A5 (input, future use) | C64 /IRQ line — not yet read in firmware |
| PHI2   | C64 → Arduino | Expansion clock | A4 (input) | C64 system clock — used to synchronize cartridge visibility and bus-drive changes |

### Clock Frequencies

| Variant | CPU Clock | Cycle Duration |
|---------|-----------|---------------|
| PAL     | 0.985 MHz | 1.015 µs      |
| NTSC    | 1.023 MHz | 0.977 µs      |

All timing figures in this document use PAL unless stated otherwise.

### /IO2 Signal Characteristics

- /IO2 is **active-low**, buffered LS TTL output on the C64 expansion port
- /IO2 goes LOW for the duration of any CPU access to $DF00–$DFFF (~1 µs = 1 cycle)

### Processor Port $01

The C64's 6510 processor port controls which ROMs/IO are visible in the address space.

| Value | Name in code | BASIC | KERNAL | I/O ($D000–$DFFF) |
|-------|-------------|-------|--------|-------------------|
| `$37` | `PP_CONFIG_DEFAULT`    | visible | visible | visible |
| `$35` | `PP_CONFIG_RAM_ON_ROM` | hidden  | visible | visible |
| `$34` | `PP_CONFIG_ALL_RAM`    | hidden  | hidden  | hidden  |

I/O must be visible (`$37` or `$35`) for $DE00 reads to work.

### GAME / EXROM and ROM Mapping

| /GAME | /EXROM | Mode       | ROML ($8000–$9FFF) |
|-------|--------|------------|---------------------|
| 0     | 1      | 8K cart    | visible             |
| 0     | 0      | 16K cart   | visible             |
| 1     | 0      | Ultimax    | visible             |
| 1     | 1      | No cart    | not visible         |

EasySD operates in **8K mode** (/GAME=0, /EXROM=1): ROML is mapped at $8000–$9FFF.
The Arduino controls /EXROM via D2.

---

## Address Map

| Address | Symbol | Description |
|---------|--------|-------------|
| `$80AB` | `CARTRIDGE_BANK_VALUE` | Arduino data output — ROML space. Arduino drives D4–D7/A0–A3; C64 reads via LDA $80AB. Used by NMI transfer and READCART_MODULATED. |
| `$DE00` | `STREAM_DATA_PORT` | Arduino data output — $DE00 space. Arduino drives D4–D7/A0–A3 via `SetPage()`; C64 reads via LDA $DE00. Used by streaming only. |
| `$DF00` | `MODULATION_ADDRESS` / `STREAM_TRIGGER_PORT` | IO2 trigger address. Any CPU read of $DF00 pulses /IO2 (FALLING edge). No data is returned from this read. |

---

## Mechanism 1 — NMI-Driven Byte Transfer

Used by all normal file loading: plugins, menu, KernalBridge.

### How It Works

1. Arduino places the next byte in its data latch ($80AB / ROML space).
2. Arduino asserts /NMI LOW (D8), triggering an NMI on the C64.
3. C64 NMI ISR (`TransferHandler` in the **ROML chip** at `$80AF`) delivers **one byte per NMI** and returns via RTI:

```asm
; Entry overhead: 7 cycles (6502 NMI dispatch)
; X = pages remaining (set by caller via ZP_IRQ_API_DATA_LENGTH)
; Y = byte index within current 256-byte page (0..255)

TransferHandler              ; 7 cycles (NMI dispatch)
    LDA CARTRIDGE_BANK_VALUE ; 4 — read byte from $80AB
    STA (ZP_IRQ_API_DATA_LO),Y ; 6 — store to target buffer
    INY                      ; 2
    BEQ ENDOFBLOCK           ; 2/3 — Y wrapped to 0: page boundary
    RTI                      ; 6 — return; Arduino sends next NMI for next byte

ENDOFBLOCK                   ; Y wrapped: page is full
    INC ZP_IRQ_API_DATA_HI   ; advance target address high byte
    DEX                      ; decrement page counter
    BEQ ENDOFTRANSFER        ; all pages done?
    RTI                      ; more pages: return; Arduino sends next NMI

ENDOFTRANSFER
    LDA #$64
    STA ZP_IRQ_STATE_WAITHANDLE  ; signal done to C64 foreground loop
    RTI
```

Each NMI delivers exactly one byte. The Arduino asserts /NMI for each byte
and the C64 ISR returns via RTI after storing it. X counts 256-byte pages;
Y counts bytes within the current page.

4. When all pages are transferred, `ZP_IRQ_STATE_WAITHANDLE` is set and the
   C64 foreground loop (polling `BIT ZP_IRQ_STATE_WAITHANDLE`) exits.

### Properties

| Property | Value |
|----------|-------|
| Data path | Arduino latch → $80AB (ROML) |
| Trigger | Arduino drives /NMI — one NMI per byte |
| Interrupt state on C64 | NMIs fire between C64 instructions; one RTI per byte |
| Transfer rate | ~40 KB/s (measured) |
| Max file size | Controlled by ZP_LF_SIZE (LoadFileBySize API, max 64 KB) |

### NMI-Session Commands (selected CartApi commands used within an open session)

| Command byte | Name | Arguments | Description |
|-------------|------|-----------|-------------|
| 27 (`0x1B`) | `COMMAND_READ_NEXT_CHUNK` | pages (1 byte) | Arduino pushes `pages×256` bytes via NMI into C64 buffer; returns status byte `0x80`=more / `0x81`=last block |
| 32 (`0x20`) | `COMMAND_HWTEST` | none | Arduino sends `SUCCESSFUL` ($80), then pushes 256 bytes via NMI: 10 known bit-patterns ($01,$02,$04,$08,$10,$20,$40,$80,$55,$AA) followed by 246 zero bytes. C64 verifies the first 10 bytes against the expected patterns to confirm data bus and NMI signal integrity. |

`COMMAND_READ_NEXT_CHUNK` is used by WavPlayer MK3 modes (`ReadNextChunk` subroutine, `WavPlayer.s`).
`COMMAND_HWTEST` is used by the HWTest plugin (`Plugins/HWTest/HWTest.s`) for hardware diagnostics.
Both commands: C64 sends via `PROT_Send`, receives status via `PROT_WaitProcessing`,
then waits for NMI handler to finish all pages.

---

## Mechanism 2 — IO2-Triggered Streaming

Used for continuous media: `StreamLargeFile` in `CartLibStream.s`,
called by WavPlayer. CvdPlayer uses Mechanism 2b (READCART_MODULATED), not this path.

### How It Works

**C64 side** (`CartLibStream.s:StreamLargeFile`):

```asm
StreamLargeFile:
    SEI              ; interrupts disabled for deterministic timing
    #SAVEREGS

_stream_loop:
    ; Check 32-bit counter (4× LDA zp + ORA + BEQ)
    LDA ZP_STREAM_API_REMAIN0
    ORA ZP_STREAM_API_REMAIN1
    ORA ZP_STREAM_API_REMAIN2
    ORA ZP_STREAM_API_REMAIN3
    BEQ _stream_done

    LDA STREAM_TRIGGER_PORT     ; LDA $DF00 — pulses /IO2 (4 cycles)
    LDA STREAM_DATA_PORT        ; LDA $DE00 — reads byte from IO1 latch (4 cycles)
    STA (ZP_STREAM_API_TARGET_LO),Y  ; store to target (6 cycles)

    INC ZP_STREAM_API_TARGET_LO ; advance pointer
    BNE +
    INC ZP_STREAM_API_TARGET_HI
+
    SEC                          ; decrement 32-bit counter
    LDA ZP_STREAM_API_REMAIN0 : SBC #$01 : STA ZP_STREAM_API_REMAIN0
    LDA ZP_STREAM_API_REMAIN1 : SBC #$00 : STA ZP_STREAM_API_REMAIN1
    LDA ZP_STREAM_API_REMAIN2 : SBC #$00 : STA ZP_STREAM_API_REMAIN2
    LDA ZP_STREAM_API_REMAIN3 : SBC #$00 : STA ZP_STREAM_API_REMAIN3
    JMP _stream_loop

_stream_done:
    #RESTOREREGS
    CLI
    CLC          ; carry clear = success
    RTS
```

**Arduino side** — on each /IO2 falling edge, `DoubleBufferedStreaming` ISR fires:

```cpp
void CartApi::DoubleBufferedStreaming() {
    lastStreamRequestTime = millis();         // reset timeout
    cartInterface.SetPage(currentByte);       // write current byte to $DE00 latch

    // pre-load next byte from active buffer
    currentByte = (usedBuffer == 0)
        ? streamBuffer1[streamBufferIndex]
        : streamBuffer2[streamBufferIndex];

    if (++streamBufferIndex == DOUBLE_BUFFER_SIZE) {
        streamBufferIndex = 0;
        usedBuffer = 1 - usedBuffer;          // signal foreground to refill
    }
}
```

**Arduino foreground** — `HandleStream()` refills buffers from SD card:

```cpp
// EXROM must be LOW before attaching the ISR.
// After NMI file transfers, DisableCartridge() leaves EXROM=HIGH (ROML disabled).
// WavPlayer's CIA1 Timer A interrupt reads CARTRIDGE_BANK_VALUE ($80AB) from ROML —
// if EXROM is HIGH, it reads RAM instead of EEPROM → silence.
cartInterface.EnableCartridge(); // EXROM LOW: ROML active at $8000-$9FFF

// Pre-fill buffer 1, attach ISR, then alternate:
while(1) {
    while(usedBuffer == 0) { check_timeout_and_sel(); }
    workingFile.read(streamingBuffer1, DOUBLE_BUFFER_SIZE);  // refill buffer 1
    while(usedBuffer == 1) { check_timeout_and_sel(); }
    workingFile.read(streamingBuffer2, DOUBLE_BUFFER_SIZE);  // refill buffer 2
}
// on exit: detach ISR, restore TIMSK2, DisableCartridge() (EXROM HIGH)
```

### Zero Page API

| ZP Address | Symbol | Description |
|------------|--------|-------------|
| `$90` | `ZP_STREAM_API_TARGET_LO` | Target address — low byte (modified during transfer) |
| `$91` | `ZP_STREAM_API_TARGET_HI` | Target address — high byte (modified during transfer) |
| `$92` | `ZP_STREAM_API_REMAIN0`   | Remaining bytes — LSB |
| `$93` | `ZP_STREAM_API_REMAIN1`   | Remaining bytes — byte 1 |
| `$94` | `ZP_STREAM_API_REMAIN2`   | Remaining bytes — byte 2 |
| `$95` | `ZP_STREAM_API_REMAIN3`   | Remaining bytes — MSB |

Caller sets target address and 32-bit byte count before calling `StreamLargeFile`.
Both values are modified in place during the transfer.

### Double Buffer

```
streamingBuffer1[64]  ←──┐ ISR reads from active buffer
streamingBuffer2[64]  ←──┘ (usedBuffer flag selects which)
                           Foreground refills the inactive buffer from SD card
```

Buffer size: 64 bytes. Total streaming buffer: 128 bytes.
`TIMSK2` is cleared during streaming to prevent Timer 2 interrupts from
competing with the /IO2 ISR; it is restored on exit.

### Termination

The C64 stops issuing LDA $DF00 when the byte counter reaches zero.
The Arduino detects no /IO2 activity for **100 ms** and exits `HandleStream()` cleanly.
This is passive termination — no explicit end-of-stream command.

### Properties

| Property | Value |
|----------|-------|
| Data path | Arduino SetPage() → D4–D7/A0–A3 → C64 data bus → $DE00 |
| Trigger | C64 reads $DF00, /IO2 FALLING edge → Arduino INT0 ISR |
| Interrupt state on C64 | SEI — interrupts disabled throughout |
| Loop overhead | ~73 cycles/byte (PAL, no page crossing) |
| Transfer rate | ~13.5 KB/s @ PAL 0.985 MHz |
| Timeout | 100 ms (Arduino side) |
| Use case | WavPlayer (8–16 KB/s) |

---

## Mechanism 2b — READCART_MODULATED (CvdPlayer)

CvdPlayer's `NMI.s` uses a hybrid read that combines the /IO2 trigger with
the ROML latch (not IO1). Used in NMI handlers, not in `StreamLargeFile`.

```asm
; Macro READCART_MODULATED expands to:
LDA MODULATION_ADDRESS      ; LDA $DF00 — pulses /IO2 (no data)
LDA CARTRIDGE_BANK_VALUE    ; LDA $80AB — reads byte from ROML latch
STA $aXXX                   ; store to video buffer
```

The Arduino ISR fires on the $DF00 read and prepares the next byte in the
ROML latch; the subsequent $80AB read retrieves it. This is used 400 times
per frame in the CVD video decoder.

---

## Timing

### C64 Data Bus Response Window

When the C64 reads from an address, valid data must be on the bus within
**~775 ns** of address assertion (6502 access time requirement: tACC ≤ 150 ns
for ROM, data setup tDSU = 100 ns before Φ2 falling edge).

For the streaming protocol, the Arduino ISR fires on the /IO2 FALLING edge
and calls `SetPage()` to drive the byte onto the data bus (D4–D7, A0–A3).
The C64 reads it with the next `LDA $DE00` instruction (~4 µs later at PAL).
This gives the Arduino adequate time.

### Arduino ISR Latency

| Parameter | Value |
|-----------|-------|
| ATmega328P INT0 minimum (theory) | 4 cycles = 0.25 µs @ 16 MHz |
| Measured latency (Nano, real hardware) | ~3.5 µs |
| C64 window between LDA $DF00 and LDA $DE00 | ~4 µs (PAL) |

The ISR fires on the $DF00 read and completes `SetPage()` before the C64
reaches the next `LDA $DE00`. Margin is tight (~0.5 µs). The byte remains
stable on the data bus (Arduino PORTD/PORTC outputs) until the next `SetPage()` call.

### Streaming Loop Cycle Budget (PAL)

| Section | Cycles |
|---------|--------|
| 32-bit counter zero check (4× ORA + BEQ) | 14 |
| LDA $DF00 + LDA $DE00 | 8 |
| STA (ptr),Y | 6 |
| INC ptr lo + BNE | 8 |
| SEC + 4× (LDA + SBC + STA) | 34 |
| JMP | 3 |
| **Total per byte** | **73** |

At 0.985 MHz PAL: 73 / 985 000 ≈ **74 µs/byte → ~13.5 KB/s**

---

## MENU/RESET Button (A6)

Arduino A6 (MENU/RESET button, analog-only pin) is connected to a tactile switch
on the PCB. The switch is normally open; pressing it connects A6 to GND.
A 10kΩ pull-up resistor from +5V to A6 holds the line HIGH when the button is
not pressed. Streaming terminates via a **100 ms timeout** if no `/IO2` pulse arrives — `HandleStream()` does not poll the SEL pin. The SEL button is checked only by the main `loop()` between commands.

A6 is analog-only on the ATmega328P — `digitalRead()`/`INPUT_PULLUP` are not
supported. The firmware uses `selRead()` (defined in `CartInterface.h`) which
wraps `analogRead(A6) >= 512`:
- Returns `true`  (≥ 512) when button is **not** pressed (A6 ≈ +5V via pull-up)
- Returns `false` (< 512) when button is **pressed** (A6 ≈ 0V via switch to GND)

The physical LED on the PCB is hardware-driven from the cartridge 5V rail — it is
always on when the cartridge has power. `STATUS_LED` (A7, pin 21) is NC on the
PCB; the `ledInit()`/`ledBootOk()` etc. calls in `StatusLed.h` toggle an NC pin
and have no visible effect.

---

## Implementation Files

| File | Role |
|------|------|
| ROML chip (`$80AF`/`$80A0`/`$808C`) | `TransferHandler` NMI ISR variants (Mechanism 1) — burned into external cartridge ROM via `IRQLoaderRom.bin` |
| `EasySD/Loader/CartLibStream.s` | `StreamLargeFile` polling loop (Mechanism 2) |
| `EasySD/Loader/CartLibCommon.s` | Address constants (`CARTRIDGE_BANK_VALUE`, `MODULATION_ADDRESS`) |
| `EasySD/Loader/CartZpMap.inc` | ZP allocation ($90–$95 streaming, $64–$77 NMI transfer) |
| `Arduino/EasySD/CartApi.cpp` | `HandleStream()`, `DoubleBufferedStreaming()` ISR |
| `Arduino/EasySD/CartInterface.h` | Arduino pin definitions, timing constants |
