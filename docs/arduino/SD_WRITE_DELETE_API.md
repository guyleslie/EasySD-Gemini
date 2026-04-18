# SD Card Write & Delete API Reference

SdFat 2.x API patterns used by EasySD firmware.

---

## Open Flags

| Flag | Value | Purpose |
|------|-------|---------|
| `O_RDONLY` | 0x00 | Read only |
| `O_WRONLY` | 0x01 | Write only |
| `O_RDWR` | 0x02 | Read and write |
| `O_APPEND` | 0x08 | Seek to EOF before each write |
| `O_CREAT` | 0x10 | Create if not exists |
| `O_TRUNC` | 0x20 | Truncate to zero length |
| `FILE_WRITE` | O_RDWR \| O_CREAT \| O_APPEND | Arduino compatibility alias |

---

## Write Pattern

```cpp
if (!file.open("data.bin", O_WRONLY | O_CREAT | O_TRUNC)) { /* error */ }

size_t wr = file.write(buf, len);
if (wr == 0 || file.getWriteError()) {
    file.clearWriteError();
    // sd.sdErrorCode() / sd.sdErrorData() for diagnosis
}

file.sync();    // flush to SD — critical, data stays in cache without this
file.close();   // also calls sync() internally
```

**Key points:**
- `write()` returns `size_t` (unsigned) — never compare against -1
- `sync()` and `flush()` are identical in SdFat 2.x
- Without `sync()`/`close()`: data is in the 512-byte internal cache, directory entry not updated
- Sync timing: ~14ms typical, up to 50–100ms on cheap cards

---

## Delete Pattern

```cpp
// Delete file by name
sd.remove("filename.txt");

// Delete empty directory
sd.rmdir("DIRNAME");
```

EasySD implementation (`CartApi.cpp`):

```cpp
if (!sd.exists(fileName)) {
    HandleResponse(FILE_NOT_FOUND, 0);
} else if (sd.remove(fileName)) {
    HandleResponse(SUCCESSFUL, 0);
} else {
    HandleResponse(FILE_DELETION_FAILED, 0);
}
```

---

## EasySD Write Buffer

| Parameter | Value |
|-----------|-------|
| `WRITE_BUFFER_SIZE` | 32 bytes |
| Internal SdFat buffer | 512 bytes (auto-flush when full) |
| Sync strategy | `sync()` after every 32-byte write block |

The 32-byte buffer is conservative but safe. SdFat internally buffers to 512-byte sectors, so actual SD writes happen only when the sector fills or `sync()` is called.

---

## Hardware Requirements

- **SD write current:** 100–200mA peak (flash programming)
- **Decoupling:** 10–100µF electrolytic + 100nF ceramic at SD module VCC/GND
- **Without capacitor:** write timeouts (0x21), data rejected (0x0D)
- **SPI:** `SPI_HALF_SPEED` (8 MHz), keep wires under 5cm
