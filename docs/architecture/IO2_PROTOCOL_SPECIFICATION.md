# IO2 Protocol Specification v1.0 (Normative)

**Document Type:** Normative (Architectural Specification)
**Version:** 1.0
**Created:** 2025-12-29 (Sprint A.1)
**Status:** CANONICAL - All IO2/streaming code MUST conform to this document
**Reference:** ARCHITECTURE_CONSOLIDATION_PLAN.md Sprint A.1

---

## Purpose and Scope

This document defines the **normative specification** for the IO2-based data streaming protocol used in the IRQHack64 system. The IO2 protocol enables high-speed, interrupt-driven data transfer from the Arduino cartridge to the C64 for streaming large files (video, audio, data > 16KB).

**This document is normative**: All future implementations of IO2 streaming MUST conform to this specification. Any deviations require architectural review and explicit documentation.

---

## 1. Hardware Layer

### 1.1 Signal Lines

| Signal | C64 Side | Arduino Side | Direction | Purpose |
|--------|----------|--------------|-----------|---------|
| **IO2** | /IO2 (cartridge slot) | Digital Pin D2 (INPUT) | C64 → Arduino | Transfer trigger (falling edge interrupt) |
| **DATA** | $DE00 (cartridge data register) | Data bus (8-bit) | Arduino → C64 | Byte transfer |
| **SEL** | Cartridge SEL line | Digital input | C64 → Arduino | Emergency abort signal |

### 1.2 IO2 Trigger Mechanism

**C64 Side:**
```assembly
LDA $DF00    ; Read from $DF00 (IO2 range)
             ; → Generates /IO2 pulse (hardware signal)
```

**Arduino Side:**
```cpp
// CartInterface.h:35
#define IO2 2    // Arduino Digital Pin 2

// ISR attachment (CartApi.cpp:905)
attachInterrupt(digitalPinToInterrupt(IO2),
                CartApi::DoubleBufferedStreaming,
                FALLING);    // Trigger on falling edge of /IO2
```

**Timing:**
- **Trigger:** C64 reads $DF00 → /IO2 line goes LOW (falling edge)
- **Duration:** /IO2 pulse width ~500ns (1 clock cycle @ 2 MHz PHI2)
- **ISR Latency:** Arduino ISR triggered within ~2μs

### 1.3 Data Read Mechanism

**C64 Side:**
```assembly
STREAM_TRIGGER_PORT = $DF00  ; IO2 trigger
STREAM_DATA_PORT    = $DE00  ; Data read

; Streaming loop (CartLibStream.s:40-42, 81-82)
_stream_loop:
    LDA STREAM_TRIGGER_PORT  ; 1. Pulse /IO2 (request next byte)
    LDA STREAM_DATA_PORT     ; 2. Read byte from $DE00
    STA (ZP_STREAM_API_TARGET_LO),Y  ; 3. Store to target buffer
```

**Arduino Side:**
```cpp
// ISR places next byte on data bus (CartApi.cpp DoubleBufferedStreaming)
// C64 reads from $DE00 → Arduino data register
```

---

## 2. C64 Side Contract

### 2.1 Function Signature

**Function:** `StreamLargeFile` (CartLibStream.s:44)

**Purpose:** Stream large files (> 16KB) from Arduino to contiguous C64 memory.

### 2.2 Zero Page API Parameters

| Address | Symbol | Type | Description |
|---------|--------|------|-------------|
| **$90-$91** | ZP_STREAM_API_TARGET_LO/HI | INPUT + LOOP VARIABLE | Target memory address (incremented during streaming) |
| **$92-$95** | ZP_STREAM_API_REMAIN0-3 | INPUT + LOOP VARIABLE | 32-bit byte count (decremented during streaming) |

**Lifetime:** Valid during StreamLargeFile execution, INVALID after return.

### 2.3 Interrupt State Contract

**CRITICAL:** Interrupts are **DISABLED** during streaming to ensure deterministic timing.

```assembly
; CartLibStream.s:45
StreamLargeFile:
    SEI                      ; Disable interrupts
    ; ... streaming loop ...
    CLI                      ; Re-enable interrupts
    RTS
```

**Rationale:**
- Prevents IRQ/NMI from corrupting ZP variables ($90-$95) during transfer
- Ensures consistent /IO2 pulse timing (no interrupt jitter)

### 2.4 Termination Contract

**Termination Mode:** PASSIVE (C64-initiated)

**Mechanism:**
1. C64 stops reading $DF00 (no more /IO2 pulses)
2. Arduino detects timeout (no request for 100ms)
3. Arduino exits HandleStream() cleanly

**NO explicit "end of stream" command** - passive termination only.

---

## 3. Arduino Side Contract

### 3.1 Function Signature

**Function:** `CartApi::HandleStream()` (CartApi.cpp:905)

**Purpose:** Respond to C64 streaming requests with double-buffered SD card data.

### 3.2 Double Buffer Architecture

```cpp
#define DOUBLE_BUFFER_SIZE 64    // CartApi.cpp:923

static uint8_t streamingBuffer1[DOUBLE_BUFFER_SIZE];
static uint8_t streamingBuffer2[DOUBLE_BUFFER_SIZE];
```

**Buffering Strategy:**
- **Buffer 1:** ISR serves bytes to C64 from this buffer
- **Buffer 2:** Main loop reads next chunk from SD card to this buffer
- **Swap:** When Buffer 1 depletes, swap buffers atomically

**Advantage:** Overlaps SD card read latency with C64 transfer (minimizes wait time).

### 3.3 ISR: DoubleBufferedStreaming()

**Trigger:** FALLING edge on IO2 pin (C64 reads $DF00)

**Action:**
1. Read next byte from current streaming buffer
2. Place byte on data bus ($DE00 equivalent)
3. Increment buffer index
4. Update `lastStreamRequestTime` (for timeout detection)

**Timing:** ISR executes in < 2μs (critical for C64 timing).

### 3.4 Main Loop: HandleStream()

```cpp
void CartApi::HandleStream() {
    attachInterrupt(digitalPinToInterrupt(IO2),
                    CartApi::DoubleBufferedStreaming, FALLING);

    while(1) {
        // Wait for buffer to be consumed by ISR
        while(usedBuffer == 0) {
            if (!digitalRead(SEL)) goto out;  // Emergency exit
            if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) goto out;  // Timeout
        }
        // Read next chunk from SD card to inactive buffer
        workingFile.read(streamingBuffer1, DOUBLE_BUFFER_SIZE);
        // ... buffer swap ...
    }
out:
    TIMSK2 = 0x02;  // Restore timer interrupts
}
```

### 3.5 Timeout Mechanism

**Constant:** `STREAM_TIMEOUT_MS = 100` (CartApi.cpp:907)

**Detection:**
```cpp
if (millis() - lastStreamRequestTime > STREAM_TIMEOUT_MS) {
    goto out;  // Exit streaming cleanly
}
```

**Rationale:**
- C64 stopped requesting bytes (passive termination)
- Arduino must exit to prevent infinite loop
- 100ms timeout is safe (C64 streams at ~400 KB/s = 2.5μs/byte)

### 3.6 Emergency Exit

**Signal:** SEL line LOW

**Check:**
```cpp
if (!digitalRead(SEL)) goto out;
```

**Purpose:** Immediate abort if cartridge is removed or hardware fault.

---

## 4. Timing Constraints

### 4.1 C64 Request Rate

**Maximum Theoretical:**
- 1 byte per 4 cycles (LDA $DF00 + LDA $DE00 = 4+4 = 8 cycles)
- @ 1 MHz: ~125,000 bytes/sec

**Measured Actual:**
- Streaming loop overhead: ~10 cycles/byte
- Actual rate: ~400 KB/s (measured)

### 4.2 Arduino Response Time

**ISR Latency:** < 2μs (from /IO2 falling edge to data available)

**Critical:** ISR MUST complete before next C64 read ($DE00) to avoid data corruption.

### 4.3 Timeout Window

**Timeout:** 100ms

**Rationale:**
- C64 byte rate: 2.5μs/byte
- 100ms = 40,000 potential byte requests
- If no request for 100ms → C64 has stopped streaming (safe to exit)

---

## 5. Error Handling

### 5.1 C64 Side Error Reporting

**Mechanism:** Carry flag

```assembly
JSR StreamLargeFile
BCS @error    ; Carry Set = error occurred
; Carry Clear = success
```

**Error Codes:** (via HandleResponse mechanism, not part of StreamLargeFile itself)

### 5.2 Arduino Side Error States

**Error Conditions:**
1. **SD Card Read Failure:** HandleStream() returns early, sets error code
2. **Timeout:** Clean exit (NOT an error - normal passive termination)
3. **SEL Line Abort:** Emergency exit (hardware issue)

**Response:**
```cpp
// After HandleStream() exits
uint8_t result = SUCCESSFUL;  // 0x00
// OR
uint8_t result = ERROR_CODE;  // Non-zero
CartApi::HandleResponse(result);
```

---

## 6. Protocol Invariants (Design Assumptions)

### 6.1 Streaming is Unidirectional

**Direction:** Arduino → C64 ONLY

**No reverse path** during streaming (C64 cannot send data mid-stream).

### 6.2 No Flow Control

**No handshaking** beyond /IO2 trigger.

**Assumption:** Arduino ISR is fast enough to always serve next byte before C64 reads $DE00.

### 6.3 File Size Known A Priori

**Requirement:** C64 MUST know file size before streaming (via IRQ_GetInfoForFile).

**Reason:** Streaming loop needs byte count to know when to stop requesting.

### 6.4 Contiguous Target Memory

**Requirement:** Target address ($90-$91) + file size MUST be contiguous valid RAM.

**No bank switching** during streaming (would break timing).

---

## 7. Test Requirements (Sprint D)

### 7.1 Functional Tests

**Test 1: 1MB File Transfer (Success Case)**
- Objective: Verify deterministic byte count and data integrity
- Expected: 1,048,576 bytes transferred, CRC32 match

**Test 2: Mid-Stream Abort (Passive Termination)**
- Objective: C64 stops requesting after 4096 bytes
- Expected: Arduino detects timeout after 100ms, exits cleanly

**Test 3: Timeout Trigger (Verify 100ms Window)**
- Objective: Measure timeout precision
- Expected: Arduino exits within 100ms ± 20ms tolerance

### 7.2 Performance Tests

**Throughput Baseline:**
- Expected: > 350 KB/s (measured average)
- Test: Stream 1 MB file, measure time

**ISR Latency:**
- Expected: < 2μs (ISR execution time)
- Test: Oscilloscope trace (/IO2 falling edge → data valid)

---

## 8. Compliance

### 8.1 Normative References

**C64 Implementation:**
- File: `IRQHack64/Loader/CartLibStream.s`
- Function: `StreamLargeFile` (line 44)
- Symbols: `STREAM_TRIGGER_PORT`, `STREAM_DATA_PORT`

**Arduino Implementation:**
- File: `Arduino/CartApi.cpp`
- Function: `HandleStream()` (line 905)
- ISR: `DoubleBufferedStreaming()`

### 8.2 Compliance Checklist

**C64 Code MUST:**
- [ ] Use $DF00 for IO2 trigger (STREAM_TRIGGER_PORT)
- [ ] Use $DE00 for data read (STREAM_DATA_PORT)
- [ ] Disable interrupts (SEI) during streaming
- [ ] Use ZP $90-$95 for API parameters
- [ ] Implement passive termination (stop requesting)

**Arduino Code MUST:**
- [ ] Attach ISR to IO2 pin (FALLING edge)
- [ ] Implement 100ms timeout detection
- [ ] Support SEL line emergency exit
- [ ] Use double buffering (or equivalent high-performance strategy)
- [ ] Restore timer interrupts on exit (TIMSK2)

---

## 9. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-29 | Sprint A.1 | Initial normative specification |

---

**Approval:** [Pending user approval]
**Effective Date:** [After Sprint A completion]

---

**END OF SPECIFICATION**
