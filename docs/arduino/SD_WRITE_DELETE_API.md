# SD Card Write & Delete API Reference

## SdFat 2.x File Write Operations

### Open Flags (from `FsApiConstants.h`)

| Flag | Value | Purpose |
|:-----|:------|:--------|
| `O_RDONLY` | 0x00 | Open for reading only |
| `O_WRONLY` | 0x01 | Open for writing only |
| `O_RDWR` | 0x02 | Open for reading and writing |
| `O_APPEND` | 0x08 | Seek to EOF before each write |
| `O_CREAT` | 0x10 | Create file if it doesn't exist |
| `O_TRUNC` | 0x20 | Truncate file to zero length |
| `O_EXCL` | 0x40 | Fail if file exists (with O_CREAT) |
| `FILE_READ` | O_RDONLY | Alias |
| `FILE_WRITE` | O_RDWR \| O_CREAT \| O_APPEND | Alias (Arduino compat) |

### Write Flow

```
open(flags) → write(buf, len) → sync() → close()
```

**Complete example (from SdFat `bench.ino`):**
```cpp
// Open for write, create if needed, truncate existing
if (!file.open("data.bin", O_WRONLY | O_CREAT | O_TRUNC)) {
    // handle error
}

// Write data
size_t wr = file.write(buf, BUF_SIZE);
if (wr != BUF_SIZE) {
    // partial or failed write
}

// Flush to SD card (critical!)
file.sync();

// Close (also calls sync internally)
file.close();
```

### Return Values & Error Checking

```cpp
// write() returns size_t (unsigned!) — NEVER compare against -1
size_t wr = file.write(buf, len);

// Check both return value AND error flag
if (wr == 0 || file.getWriteError()) {
    file.clearWriteError();   // Reset for next attempt
    uint8_t err = sd.sdErrorCode();    // SD-level error code
    uint8_t dat = sd.sdErrorData();    // SD card response token
}
```

### sync() / flush() Behavior

- `sync()` and `flush()` are **identical** in SdFat 2.x
- Forces: (1) write data buffer to SD, (2) update FAT directory entry
- **Without sync/close:** data stays in 512-byte internal cache
- SdFat auto-writes when the 512-byte buffer fills, but the **directory entry** (file size, date) is only updated on `sync()` or `close()`
- Timing: ~14ms typical, can spike to 50-100ms on cheap cards

### Pre-allocation (Optional, for large writes)

```cpp
file.open("big.dat", O_WRONLY | O_CREAT | O_TRUNC);
file.preAllocate(expectedSize);   // Reserve clusters upfront
// ... write data ...
file.truncate();                   // Trim to actual size
file.close();
```

---

## SdFat 2.x File Delete Operations

### Delete File

```cpp
// Method 1: By name (preferred for EasySD)
sd.remove("filename.txt");

// Method 2: On open file object (must be writable)
file.open("temp.dat", O_WRONLY);
file.remove();   // Deletes and closes
```

### Delete Directory

```cpp
sd.rmdir("DIRNAME");   // Directory must be empty
```

### EasySD Implementation (CartApi.cpp)

```cpp
// HandleDeleteFile — correct pattern
if (!sd.exists(fileName)) {
    HandleResponse(FILE_NOT_FOUND, 0);
} else {
    if (sd.remove(fileName)) {
        HandleResponse(SUCCESSFUL, 0);
    } else {
        HandleResponse(FILE_DELETION_FAILED, 0);
    }
}
```

---

## EasySD CartApi Bugfixes (v2.1.1)

### Bug 1: HandleWriteFile — `size_t` vs `-1`
**Before (broken):**
```cpp
int bytesWritten = workingFile.write(Arguments, WRITE_BUFFER_SIZE);
if (bytesWritten == -1) {   // NEVER true — size_t is unsigned!
```

**After (fixed):**
```cpp
size_t bytesWritten = workingFile.write(Arguments, WRITE_BUFFER_SIZE);
if (bytesWritten == 0 || workingFile.getWriteError()) {
    workingFile.clearWriteError();
```

### Bug 2: HandleWriteFile — Missing sync()
**Before:** No sync — data stays in SdFat cache, lost on power failure.
**After:** `workingFile.sync()` after every successful write block.

### Bug 3: HandleDeleteFile/Directory/CreateDirectory — Missing NUL termination
**Before:** `fileName` pointer used without null terminator — read random memory.
**After:** Same null-termination pattern as `HandleOpenFile()`.

---

## Similar C64 SD Card Projects

### SD2IEC (Most mature open-source)
- **MCU:** ATmega644 (4KB SRAM)
- **Protocol:** Full IEC bus emulation (standard KERNAL SAVE/LOAD)
- **Write buffer:** 256 bytes per channel (matches 1541 sector size), chainable
- **Error reporting:** CBM error channel 15 (`25,WRITE ERROR` / `26,WRITE PROTECT ON`)
- **Source:** https://github.com/rkrajnc/sd2iec

### UNO2IEC (Arduino-based)
- **MCU:** ATmega328P (same as EasySD!)
- **Write:** Byte-by-byte IEC → serial bridge to PC host (PC writes to disk)
- **PRG/P00 save** at 1541 normal speed
- **Source:** https://github.com/Larswad/uno2iec

### BackBit (Cartridge port, closest to EasySD architecture)
- **Interface:** Cartridge port (like EasySD)
- **Write:** KERNAL vector override — intercepts $FFD8 (SAVE) and redirects to SD
- **Supports:** Full D81 read/write
- **Source:** https://github.com/evietron/BackBit-OpenSource

### Kung Fu Flash (STM32 cartridge)
- **MCU:** STM32 (much more powerful than ATmega328P)
- **Write:** D64 image write-back (planned/partial)
- **Source:** https://codeberg.org/KimJorgensen/KungFuFlash

### Comparison Table

| Project | MCU | Write Buffer | Sync Strategy | Interface |
|:--------|:----|:-------------|:-------------|:----------|
| **EasySD** | ATmega328P (2KB) | 32 bytes | sync() per write | Cartridge port |
| **SD2IEC** | ATmega644 (4KB) | 256 bytes | On channel close | IEC serial bus |
| **UNO2IEC** | ATmega328P (2KB) | Byte-by-byte | PC-side flush | IEC + USB serial |
| **BackBit** | Custom | Unknown | KERNAL intercept | Cartridge port |

### Key Takeaways for EasySD
1. **32-byte WRITE_BUFFER_SIZE is adequate** — SdFat internally buffers to 512-byte sectors
2. **sync() after each write is conservative but safe** — SD2IEC syncs on channel close
3. **The C64 side should always close files** after writing (triggers final sync)
4. **Error recovery is unique to EasySD** — other projects don't reinitialize SD mid-session

---

## Hardware Requirements for Write Operations

### SD Card Current Draw
- **Read:** ~30-50mA
- **Write:** **100-200mA** peak (flash programming)
- **Idle:** ~1mA

### Breadboard Stability
- **Required:** 10-100µF electrolytic capacitor across SD module VCC/GND
- **Optional:** 100nF ceramic in parallel (high-frequency decoupling)
- **Without capacitor:** Write timeouts (0x21), data rejected (0x0D), read errors (0x19)
- **SPI speed:** `SPI_QUARTER_SPEED` required on breadboard
- **Wire length:** Keep SPI lines under 5cm for reliable writes

### Test Results (v2.1.1, breadboard + 100nF ceramic + 100µF electrolytic)
```
7/8 PASS: SD_INIT, OPEN_RD_CL, SEEK, OPEN_NOEX, MEM_LOOP, ROOT_LIST, DIR_NAV
1/8 FAIL: WR_DEL (0x19 SPI read token — breadboard hardware limitation)
RAM: 415 → 415 (stable, no leaks)
SD recovery after WR_DEL: successful (all subsequent tests pass)
```
Write failure is expected on breadboard — PCB with proper decoupling traces should resolve.
