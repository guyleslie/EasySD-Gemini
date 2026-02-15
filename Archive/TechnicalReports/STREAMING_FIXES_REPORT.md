# EasySD Gemini - Comprehensive Streaming System Report
**Date:** 2025.12.21.
**Project:** Unified Streaming Architecture Optimization (WAV, PRG, CVID)

## 1. Overview of the Streaming Infrastructure
The EasySD / IRQHack64 system uses a specialized hardware-software interface to stream data from an SD card to the Commodore 64 via the Expansion Port. The core of this system is the **NMI (Non-Maskable Interrupt)** signaling, which allows the Arduino to act as a "Pseudo-DMA" controller.

### The Two Main Streaming Modes:
1.  **Interrupt-Based Streaming (`COMMAND_STREAM`):** Primarily used for audio (WAV) playback. It uses the Arduino's hardware interrupts to serve data at precise intervals.
2.  **Polling-Based "NI" Streaming (`COMMAND_NI_STREAM`):** Used for high-speed video (CVID) and custom loaders. It uses a tight polling loop for maximum throughput.

## 2. Project-Wide Streaming Improvements

### 2.1. Unified Buffer Management
- **Change:** Increased `DOUBLE_BUFFER_SIZE` from 256 to **400 bytes** in `CartApi.h`.
- **Reason:** To support the 400-byte block structure of the video plugin while allowing the WAV player and standard loaders to share the same optimized memory space.
- **Impact:** Unified memory footprint across all streaming plugins and improved stability for large-block transfers.

### 2.2. Global Double-Buffering Implementation
The transition from single-buffering to double-buffering (Ping-Pong) has been applied to eliminate "SD Latency Jitter".
- **Double-Buffered NI Stream:** The `HandleNonInterruptedStream` function now pre-fetches data into a second buffer while the C64 is processing the previous block.
- **Background SD Access:** By utilizing the C64's "processing time" (e.g., during screen drawing), the Arduino refreshes its buffers without blocking the NMI response loop.

## 3. Specific Plugin Enhancements

### 3.1. Video (CVID / BurstLoader)
- **Pre-swizzled Data Support:** Optimized for 400-byte blocks (320 bitmap + 80 color).
- **Dynamic Loading:** Replaced hardcoded filenames with dynamic retrieval from `CASSETTEBUFFER`.
- **VBlank Synchronization:** Set `STARTRASTER = 241` to align transfers with the vertical blanking period, eliminating screen tearing.

### 3.2. Audio (WAV Player)
- **Buffer Stability:** The unified 400-byte buffer provides a larger "safety margin" for audio streaming, reducing the risk of underruns during SD card spikes.
- **Buffered Playback:** C64-side implementation uses a 128-byte local buffer to further decouple audio synthesis from hardware transfer latency.

### 3.3. General Loader Improvements
- **STOP Key Support:** Implemented `$FFE1` detection across streaming plugins, allowing clean exits to the menu by restoring the Kernal and CPU state ($01).

## 4. Technical Analysis (Origins & Validation)
The system remains faithful to the original "Istanbul" implementation by **Nejat Dilek** and **Özay Turay**, maintaining high-speed NMI synchronization. 

- **Pseudo-DMA:** Each byte is transferred in 8-10 cycles via `LDA MODULATION_ADDRESS` + `LDA CARTRIDGE_BANK_VALUE`.
- **Double Buffering Impact:** Our tests show that by offloading SD latency to the Arduino's background cycle, we achieve stability comparable to ROM-based solutions (like EasyFlash) while maintaining the flexibility of SD card streaming.

## 5. Affected Files
- **Arduino/IRQHack64/CartApi.h**: Buffer size definitions.
- **Arduino/IRQHack64/CartApi.cpp**: Double-buffering logic in `HandleNonInterruptedStream`.
- **IRQHack64/Plugins/BurstLoader/BurstLoader.s**: Dynamic loading and STOP key handling.
- **IRQHack64/Plugins/WavPlayer/WavPlayer.s**: Audio streaming stability via buffered NMI.
- **IRQHack64/Loader/SafeStreamImpl.s**: Unified profile management for different streaming speeds.
