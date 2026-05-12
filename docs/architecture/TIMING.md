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
| SD card errors during transfer | `EasySD.ino` — `SPI_FULL_SPEED` | SPI clock rate |

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
                           →  Arduino INT1 ISR fires (latency: ~3.5 µs measured)
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
> Without it, EXROM is HIGH and $80AB reads return RAM instead of ROML chip data.

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

## 3. WavPlayer MK3 — NMI chunk transfer (COMMAND_READ_NEXT_CHUNK)

**Files:** `EasySD/Plugins/WavPlayer/WavPlayer.s`, `Arduino/EasySD/CartApi.cpp`

Unlike IO2 streaming, MK3 mode uses a double-buffer scheme: the C64 requests
`BUFFER_PAGES × 256` bytes from Arduino via NMI, stores them in a RAM buffer,
and a CIA1 ISR forwards each byte to the DigiMax MK3 via CIA2 DATA_B ($DD01)
at the configured sample rate. The MK3 has an internal 4096-byte FIFO and plays
independently once buffered.

### Rate calibration (N+1 formula)

CIA 6526 timer period = **N+1 clocks** (CIA datasheet, confirmed by Lemon64 forum):
- CIA1 timer=89 → 985248 / 90 = **10947 Hz** (not 11025/11070 Hz)
- CIA1 timer=44 → 985248 / 45 = **21894 Hz** (not 22050/22392 Hz)

ATmega CTC timer period = **OCR1A+1 counts** (ATmega328P datasheet):
- OCR1A=1450 → 16000000 / 1451 = **11026 Hz** (MK3 default, 79 Hz faster than C64)
- OCR1A=1461 → 16000000 / 1462 = **10944 Hz** (calibrated, +2.6 B/s inflow)
- OCR1A=725  → 16000000 / 726  = **22039 Hz** (MK3 old, 145 Hz faster than C64)
- OCR1A=730  → 16000000 / 731  = **21888 Hz** (calibrated, +6.0 B/s inflow)

**Without calibration**: MK3 always runs slightly faster than the C64, draining the
4096-byte FIFO in seconds (11K) or seconds (22K) → underrun → audio stops.

**With calibration** (sent via `MK3_ConfigureMode`): MK3 runs slightly slower than
C64 → FIFO fills at +2.6–6.0 B/s → sustained playback with no underrun.

### Buffer and transfer

| Parameter | Value | Notes |
|-----------|-------|-------|
| `BUFFER_PAGES` | 24 | → 6144 bytes per buffer |
| Two buffers total | 12288 bytes | `AUDIO_BUF_A` + `AUDIO_BUF_B` in plugin RAM |
| Transfer function | `TransmitByteFastMK3()` | 35µs delay → 22133 Hz fill rate |
| Transfer time (6144 B) | **~295 ms** | 6144 × ~48 µs/byte (NMI + SD read interleaved) |

### Playback duration per buffer by mode

CIA1 timer uses N+1 rule; rates below are actual:

| Mode | CIA1 timer | C64→MK3 rate | MK3 OCR1A | MK3 rate | Buffer duration | Refill time | Margin |
|------|-----------|-------------|-----------|----------|-----------------|-------------|--------|
| PLAYTYPE_MK3 (11K mono) | 89 | **10947 Hz** | 1461 | **10944 Hz** | **561 ms** | ~295 ms | **+266 ms ✓** |
| PLAYTYPE_MK3_22K (22K mono) | 44 | **21894 Hz** | 730 | **21888 Hz** | **281 ms** | ~295 ms | **−14 ms** |
| PLAYTYPE_MK3_STEREO (stereo) | 44 | **21894 B/s** | 1461 | **21889 B/s** | **281 ms** | ~295 ms | **−14 ms** |

> **Note — 22K and stereo modes:** with `TransmitByteFastMK3` the fill rate
> (22133 Hz) exceeds the C64 ISR rate (21894 Hz). The NMI fill completes faster
> than playback → buffer is always ready before the ISR needs it. The −14 ms margin
> is a worst-case approximation; in practice the stale-read guard (`ZP_WAV_SILENCE`)
> outputs mid-scale silence for any remaining gap, inaudible at 22 kHz.

### Stale-read guard

`ZP_WAV_BUF_READY` ($92) and `ZP_WAV_SILENCE` ($93) prevent ISR from reading
partially-filled buffer data:

- `ReadNextChunk` clears `ZP_WAV_BUF_READY` at start, sets it to 1 after `WAITFOR`.
- `PF_SWAP` (ISR): if `ZP_WAV_BUF_READY=0`, enters silence mode instead of swapping.
- ISR silence path: sends `$80` (mid-scale) to `$DD01` without advancing pointer.
- Main loop: clears `ZP_WAV_SILENCE` after `ReadNextChunk` returns → ISR resumes
  from start of freshly filled buffer on the next tick.

### Sequence diagram

```
C64 main loop                  C64 CIA1 ISR (21894 Hz)      Arduino
─────────────────              ──────────────────────       ──────────────────────
ReadNextChunk(BUF_A) ────────────────────────────────────→ send 6144B via NMI (~295ms)
ReadNextChunk(BUF_B) ────────────────────────────────────→ send 6144B via NMI (~295ms)
CLI (start ISR)
                               reads BUF_A → $DD01 (MK3)
[idle loop]                    …at 21894 Hz…
                               BUF_A done → swap to BUF_B, set FILL flag
ReadNextChunk(BUF_A) ────────────────────────────────────→ send 6144B via NMI (~295ms)
                               reads BUF_B → $DD01 (MK3)
                               BUF_B done (281ms) → check BUF_READY:
                                 ready → swap to BUF_A normally
                                 not ready → ZP_WAV_SILENCE=1, send $80 until ready
```

---

## 4. READCART_MODULATED — CVD video (CvdPlayer)

**Files:** `EasySD/Plugins/CvdPlayer/NMI.s`, `EasySD/Loader/SystemMacros.s`

Used 400× per frame in the CVD NMI handlers (not in `StreamLargeFile`).

```asm
; READCART_MODULATED \1  expands to:
LDA MODULATION_ADDRESS    ; $DF00 — pulse /IO2 (4 cycles)
LDA CARTRIDGE_BANK_VALUE  ; $80AB — read byte from ROML latch (4 cycles)
STA \1                    ; store to video buffer (3–6 cycles)
; total: ~11–14 cycles per byte
```

For this tight path the Arduino NI loop precomputes the outgoing PORTD/PORTC
values while waiting for /IO2, then latches them immediately after /IO2 returns
high. This matches the official IRQHack64 NI-stream handshake: `$DF00` is the
trigger, and the following `$80AB` read retrieves the byte from ROML.

The AVR clears `CARTRIDGE_BANK_VALUE` before the first SD preload and raises
`SUCCESSFUL` only after the first 400-byte block is resident in SRAM. The C64
therefore waits in `PROT_WaitProcessing` until the NI stream is actually ready;
the post-`PROT_NIStream` two-frame delay is retained to match the original
BurstLoader startup cadence and provide deterministic raster setup margin.

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

## 5. Timing macros (SystemMacros.s)

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

## 6. SPI / SD card

SdFat is initialised at `SPI_FULL_SPEED`. No reduced SPI speed profile is used.

---

## 7. All empirical timing values at a glance

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
| `WavPlayer.s` `BUFFER_PAGES` | **24** pages = 6144 B | MK3 double-buffer size per half |
| `WavPlayer.s` CIA1 timer (11K) | **89** | 985248/(**89+1**) = **10947 Hz** (N+1 rule) |
| `WavPlayer.s` CIA1 timer (22K) | **44** | 985248/(**44+1**) = **21894 Hz** (N+1 rule) |
| `WavPlayer.s` MK3 OCR1A (11K) | **1461** | 16000000/(1461+1) = **10944 Hz** ≈ C64 10947 Hz |
| `WavPlayer.s` MK3 OCR1A (22K) | **730** | 16000000/(730+1)  = **21888 Hz** ≈ C64 21894 Hz |
| `CartApi.cpp` `HandleReadNextChunk` | **1 ms** delay | Gap between status byte and NMI start |
| `CartInterface.cpp` `TransmitByteFastMK3` | Post-NMI: **35 µs** | MK3 path: 22133 Hz fill > 21894 Hz ISR |

---

## 8. Tuning history

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
