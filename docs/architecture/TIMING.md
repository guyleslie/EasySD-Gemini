# EasySD Timing Reference

All data transfer between the Arduino and C64 depends on precise timing.
This document is the **single reference** for timing-critical values, their
locations in the code, and what to check when something breaks.

---

## Quick reference: where to look

| Symptom | First file to check | Key lines |
|---------|--------------------|-----------|
| File loading fails / corrupted data | `CartInterface.cpp` — `TransmitByteFast()` | NMI pulse width, inter-byte delay |
| Streaming audio glitches / dropouts | `CartApi.cpp` — `DoubleBufferedStreaming()` | ISR timing, buffer size |
| CVD video tears / sync loss | `CvdPlayer/CvdPlayer.s` | `STARTRASTER = 241` |
| Hang after file operation | `CartLib.s` — `TransferHandler` / `WAITFOR` | Page counter X, ZP_IRQ_STATE_WAITHANDLE |
| SD card errors during transfer | `CartInterface.cpp` — `SPI_QUARTER_SPEED` | SPI clock rate |

---

## 1. NMI Transfer — file loading

**Files:** `Arduino/EasySD/CartInterface.cpp`, `EasySD/Loader/CartLib.s`

### Arduino side (CartInterface.cpp)

Three transmit variants, each with different delays:

| Function | NMI pulse width | Post-NMI delay | Used for |
|----------|----------------|----------------|---------|
| `TransmitByteFast()` | **10 µs** | **50 µs** (normal), **80 µs** (block end) | Main file transfer |
| `TransmitByteSlow()` | **10 µs** | **75 µs** | Initialization / protocol handshake |
| `TransmitByteBlockEnd()` | **6 µs** | **100 µs** | Last byte of a 256-byte block |

**Empirically tuned:** original values (5–7 µs pulse, 31–40 µs delay) caused
intermittent failures on real hardware. Current values include a safety margin.

```
SetPage(byte)          — put byte on PORTD/PORTC data bus
NmiLow()               — assert /NMI (open-collector: set pin as OUTPUT low)
delay 10 µs            — hold long enough for C64 to latch the NMI
NmiHigh()              — release /NMI (set pin as INPUT with pullup)
delay 50 µs            — wait for TransferHandler ISR to complete
```

> **If NMI transfer breaks:** increase the post-NMI delay first (50 → 60–70 µs).
> If failures only happen at block boundaries, increase the block-end delay (80 → 100 µs).

### C64 side (CartLib.s — TransferHandler)

One NMI delivers exactly one byte. The ISR takes ~27 cycles at PAL 1 MHz ≈ 27 µs.
That is why the Arduino must wait at least 27 µs before the next NMI.
The 50 µs inter-byte delay provides ~23 µs margin.

```asm
; Y = byte index within current 256-byte page
; X = pages remaining (set by caller)

TransferHandler          ; 7 cycles  — NMI dispatch overhead
    LDA CARTRIDGE_BANK_VALUE  ; 4  — read byte from $80AB (ROML)
    STA (ZP_IRQ_API_DATA_LO),Y ; 6 — store to target buffer
    INY                       ; 2  — next byte position
    BEQ ENDOFBLOCK            ; 2/3 — page full (Y wrapped to 0)?
    RTI                       ; 6  — return; Arduino sends next NMI
                              ;       total normal path: ~27 cycles

ENDOFBLOCK
    INC ZP_IRQ_API_DATA_HI   ; advance target page
    DEX                      ; pages remaining--
    BEQ ENDOFTRANSFER
    RTI

ENDOFTRANSFER
    LDA #$64
    STA ZP_IRQ_STATE_WAITHANDLE  ; signal done → foreground BVC loop exits
    RTI
```

**Foreground polling loop** (`CartLib.s`, uses `WAITFOR` macro):
```asm
CLV
#WAITFOR ZP_IRQ_STATE_WAITHANDLE, BVC   ; spin until ENDOFTRANSFER sets bit 6
```
> ⚠️ `WAITFOR` has **no timeout** — if the transfer never completes the C64 hangs here.

### /NMI open-collector wiring

`NmiLow()` switches D8 to OUTPUT (drives 0V).
`NmiHigh()` switches D8 to INPUT (pullup releases the line).
The C64 expansion port /NMI line has its own pull-up. No direct Arduino drive to 5V.

---

## 2. IO2 Streaming — WAV / audio playback

**Files:** `Arduino/EasySD/CartApi.cpp`, `EasySD/Loader/CartLibStream.s`

### Timing window

```
C64 executes LDA $DF00    →  /IO2 pulse (LOW ~1 µs)
                           →  Arduino INT0 ISR fires (latency: ~3.5 µs measured)
                           →  DoubleBufferedStreaming() calls SetPage(currentByte)
                              (~4-5 cycles on 16 MHz Arduino = ~0.3 µs)
C64 executes LDA $DE00    →  reads byte from PORTD/PORTC
  (4 µs after $DF00 read)
```

**Window:** ~4 µs between the $DF00 read and the $DE00 read.
ISR latency (~3.5 µs) + SetPage (~0.3 µs) ≈ 3.8 µs. Margin: **~0.2 µs**.
This is tight. Any ISR latency increase (competing interrupt, TIMSK2 not disabled)
can miss the window.

### Key settings (CartApi.cpp)

```cpp
DOUBLE_BUFFER_SIZE  = 64         // bytes per half-buffer; total SRAM: 128 bytes
STREAM_TIMEOUT_MS   = 100        // ms of IO2 silence → exit streaming
TIMSK2 = 0                       // MUST disable Timer 2 before attaching IO2 ISR
cartInterface.EnableCartridge()  // EXROM LOW: ROML active (needed for $80AB reads)
```

> **If streaming drops out:** check that `TIMSK2 = 0` is set before
> `attachInterrupt()`. A Timer 2 interrupt competing with the IO2 ISR
> can delay `SetPage()` past the 4 µs window.

> **If streaming is silent (WAV plays but no audio):** check that
> `EnableCartridge()` is called before the ISR is attached.
> Without it, EXROM is HIGH and $80AB reads return RAM instead of EEPROM data.

### C64 streaming loop cycle count (CartLibStream.s)

| Step | Cycles |
|------|--------|
| 32-bit zero check (4× ORA + BEQ) | 14 |
| LDA $DF00 + LDA $DE00 | 8 |
| STA (ptr),Y | 6 |
| INC ptr lo + BNE | 8 |
| SEC + 4× (LDA + SBC + STA) | 34 |
| JMP | 3 |
| **Total per byte** | **73** |

73 cycles ÷ 985 000 Hz (PAL) ≈ **74 µs/byte → ~13.5 KB/s**

Interrupts are disabled (`SEI`) for the entire streaming loop. The Arduino
detects end-of-stream by a 100 ms timeout on /IO2 activity.

---

## 3. READCART_MODULATED — CVD video (CvdPlayer)

**Files:** `EasySD/Plugins/CvdPlayer/NMI.s`, `EasySD/Loader/SystemMacros.s`

Used 400× per frame in the CVD NMI handlers (not in `StreamLargeFile`).

```asm
; READCART_MODULATED \1  expands to:
LDA MODULATION_ADDRESS    ; $DF00 — pulse /IO2 (4 cycles)
LDA CARTRIDGE_BANK_VALUE  ; $80AB — read byte from ROML latch (4 cycles)
STA \1                    ; store to video buffer (3–6 cycles)
; total: ~11–14 cycles per byte
```

### Raster synchronisation

```
STARTRASTER = 241    (CvdPlayer.s)
```

The CvdPlayer installs its NMI handler at raster line 241 — the start of
the vertical blank on PAL (312 lines/frame). This gives the NMI handler
~71 lines × 63 cycles/line ≈ **4500 cycles of blanking time** to transfer
one 256-byte frame without VIC-II cycle stealing.

> ⚠️ **PAL only.** NTSC has only 263 lines. STARTRASTER=241 falls in the
> visible area on NTSC → screen tearing and incorrect timing.
> An NTSC build would need `STARTRASTER ≈ 230`.

---

## 4. Timing macros (SystemMacros.s)

### WAITFOR

```asm
WAITFOR .macro
-   BIT \1       ; 3 cycles — test flags
    \2 -         ; 2 cycles — branch (BEQ/BNE/BVC/BVS/BPL/BMI)
.endm
```

5 cycles per loop iteration. **No timeout.** Used to wait for
`ZP_IRQ_STATE_WAITHANDLE` after NMI transfers.

> ⚠️ If the transfer stalls (e.g. Arduino crashes mid-transfer), the C64
> hangs here forever. There is no watchdog or timeout on the C64 side.

### WAITVALUE

```asm
WAITVALUE .macro
-   LDA \1       ; 3 cycles
    CMP #\2      ; 2 cycles
    BNE -        ; 2 cycles
.endm
```

7 cycles per iteration. Same infinite-loop risk as WAITFOR.

---

## 5. SPI / SD card

SdFat is initialised at `SPI_QUARTER_SPEED` (400 kHz).

> **Do not increase SPI speed.** Higher speeds cause SD card read errors on
> breadboard and PCB builds due to line capacitance and the lack of
> impedance matching on the SPI traces.

---

## 6. All empirical timing values at a glance

| Location | Value | What it controls |
|----------|-------|-----------------|
| `CartInterface.cpp` `TransmitByteFast()` | NMI pulse: **10 µs** | C64 NMI latch time |
| `CartInterface.cpp` `TransmitByteFast()` | Post-NMI: **50 µs** (normal) | Wait for TransferHandler ISR |
| `CartInterface.cpp` `TransmitByteFast()` | Post-NMI: **80 µs** (block end) | Extra margin at 256-byte boundary |
| `CartInterface.cpp` `TransmitByteSlow()` | Post-NMI: **75 µs** | Conservative startup timing |
| `CartInterface.cpp` `TransmitByteBlockEnd()` | Post-NMI: **100 µs** | Block-end safety margin |
| `CartInterface.cpp` `StreamByte()` | NMI pulse: **10 µs** | (streaming NMI path) |
| `CartInterface.cpp` `ResetC64()` | Reset pulse: **1000 µs** | C64 reset hold time |
| `CartApi.cpp` `HandleStream()` | Timeout: **100 ms** | IO2 silence → exit streaming |
| `CartApi.cpp` `HandleStream()` | Buffer: **64 bytes** × 2 | Double-buffer SRAM budget |
| `CvdPlayer.s` | `STARTRASTER = 241` | PAL vertical blank start |
| `CartLib.s` `TransferHandler` | **27 cycles** / byte | NMI ISR execution time (PAL) |
| `CartLibStream.s` `StreamLargeFile` | **73 cycles** / byte | Streaming loop (→ 13.5 KB/s) |

---

## 7. Tuning history

These values were increased from original after hardware failures:

| Value | Original | Current | Reason |
|-------|----------|---------|--------|
| NMI pulse width (fast) | 6–7 µs | 10 µs | Too close to C64 minimum NMI latch time |
| Inter-byte delay (fast) | 31 µs | 50 µs | TransferHandler ISR sometimes not finished |
| StreamByte NMI pulse | 5 µs | 10 µs | Empirical failure on real hardware |
| Block-end delay | 80 µs | 100 µs | State machine transition needs extra slack |

> If new hardware (e.g. faster SD card, different C64 board revision) causes
> failures, **increase delays in small increments** (5–10 µs) rather than
> rewriting the transfer logic.
