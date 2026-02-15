# File I/O Core API - Test Suite Documentation

**Created:** 2025-12-26
**Component:** POST_SPRINT6_PLAN D4
**Status:** Ready for manual testing

---

## Overview

This test suite validates the File I/O Core API (`HandleOpenFile`, `HandleReadFile`, `HandleCloseFile`) implemented in `CartApi.cpp`.

**Test Coverage:**
- Basic file operations (OPEN/READ/CLOSE)
- Error handling (FILE_NOT_FOUND, FILE_IS_NOT_OPENED, etc.)
- Edge cases (directory open, read after close)
- Memory stability (50× stress test)

---

## Prerequisites

### 1. Hardware Setup
- Arduino Nano with EasySD firmware
- SD card with test files (see below)
- Serial connection (USB cable)

### 2. Firmware Build
**IMPORTANT:** Must use **DEBUG build** to see test results!

```bash
cd "C:\EasySD Gemini"
python Tools/build.py debug-arduino
python Tools/arduino_build_upload.py upload COM4  # Replace COM4 with your port
```

### 3. Test Files on SD Card

Create these files on your SD card:

```
/
├─ TESTFILE_SMALL.BIN   (256 bytes - any content)
├─ TESTFILE_LARGE.BIN   (2048 bytes - any content)
└─ UTILS/                (directory - should exist from navigation tests)
```

**Quick create (Windows):**
```batch
fsutil file createnew E:\TESTFILE_SMALL.BIN 256
fsutil file createnew E:\TESTFILE_LARGE.BIN 2048
```

**Quick create (Linux/Mac):**
```bash
dd if=/dev/urandom of=/media/sd/TESTFILE_SMALL.BIN bs=256 count=1
dd if=/dev/urandom of=/media/sd/TESTFILE_LARGE.BIN bs=256 count=8
```

---

## Running Tests

### Option 1: Semi-Automated Test Suite (Recommended)

```bash
cd "C:\EasySD Gemini\Tools"
python test_file_io.py COM4  # Replace COM4 with your port
```

The script will:
1. Connect to Arduino
2. Guide you through each test scenario
3. Prompt you to verify Arduino Serial Monitor output
4. Run all 6 scenarios

**You must:**
- Keep Arduino Serial Monitor open (Tools → Serial Monitor in Arduino IDE, 57600 baud)
- Verify each command's debug output
- Press Enter to continue after each verification

### Option 2: Manual Testing

Open Arduino Serial Monitor (57600 baud) and follow the test plan in `test_file_io.py` comments.

---

## Test Scenarios

### Scenario 1: Small File Read
**Flow:** OPEN → READ → CLOSE

**Expected Serial Output:**
```
[INFO] Got HandleOpenFile
  Filename: /TESTFILE_SMALL.BIN
  Path type: ABSOLUTE
[INFO] Success!
[INFO] Got HandleReadFile
  Actual length: 256
  Total length: 256
[INFO] Got HandleCloseFile
  Closed!
```

**Pass Criteria:** ✅ All commands return SUCCESSFUL (0x80)

---

### Scenario 2: Large File Read
**Flow:** OPEN → READ (8× 256 bytes) → CLOSE

**Expected Serial Output:**
```
[INFO] Got HandleOpenFile
  Filename: /TESTFILE_LARGE.BIN
  Success!
[INFO] Got HandleReadFile (x8)
  Actual length: 256 (each iteration)
[INFO] Got HandleCloseFile
  Closed!
```

**Pass Criteria:**
- ✅ All READ commands succeed
- ✅ File pointer advances correctly (8 chunks × 256 bytes = 2048 bytes total)

---

### Scenario 3: READ After CLOSE
**Flow:** OPEN → CLOSE → READ (should fail)

**Expected Serial Output:**
```
[INFO] Got HandleOpenFile
  Success!
[INFO] Got HandleCloseFile
  Closed!
[INFO] Got HandleReadFile
[ERR ] Not initialized!
CMD RESULT: 0x04  ← FILE_IS_NOT_OPENED
```

**Pass Criteria:** ✅ READ after CLOSE returns `FILE_IS_NOT_OPENED` (0x04)

---

### Scenario 4: File Not Found
**Flow:** OPEN non-existent file

**Expected Serial Output:**
```
[INFO] Got HandleOpenFile
  Filename: /NONEXISTENT_FILE.BIN
[ERR ] Fail!
CMD RESULT: 0x03  ← FILE_CANNOT_BE_OPENED (may also be 0x02 FILE_NOT_FOUND)
```

**Pass Criteria:** ✅ OPEN returns error code (NOT 0x80)

---

### Scenario 5: OPEN Directory
**Flow:** OPEN directory path

**Expected Serial Output:**
```
[INFO] Got HandleOpenFile
  Filename: /UTILS
[ERR ] Fail!
CMD RESULT: 0x03  ← FILE_CANNOT_BE_OPENED
```

**Pass Criteria:** ✅ OPEN directory returns `FILE_CANNOT_BE_OPENED` (0x03)

---

### Scenario 6: Stress Test (Memory Leak Check)
**Flow:** 50× (OPEN → READ → CLOSE)

**Expected Serial Output:**
```
Iteration 1/50:
  [INFO] Got HandleOpenFile → Success!
  [INFO] Got HandleReadFile → 256 bytes
  [INFO] Got HandleCloseFile → Closed!
  [DIR] Prep: / (3 items, 437 bytes free)  ← Check RAM stays stable

Iteration 2/50:
  ...
  [DIR] Prep: / (3 items, 437 bytes free)  ← Should be same as iteration 1

...

Iteration 50/50:
  ...
  [DIR] Prep: / (3 items, 437 bytes free)  ← Should be same as iteration 1
```

**Pass Criteria:**
- ✅ All 50 iterations succeed
- ✅ Free RAM remains constant (±5 bytes tolerance)
- ✅ No crashes or hangs

---

## Interpreting Results

### Success Indicators
- `CMD RESULT: 0x80` (SUCCESSFUL)
- No "FAIL" or "ERR" messages for happy-path scenarios
- RAM stability over 50 iterations

### Failure Indicators
- Unexpected error codes (e.g., SUCCESSFUL when should be FILE_NOT_FOUND)
- RAM degradation (free bytes decreasing over iterations)
- Crashes or hangs

---

## Troubleshooting

### "Not seeing any Serial output"
- ✅ Check: DEBUG build uploaded? (not release build)
- ✅ Check: Serial Monitor set to 57600 baud
- ✅ Check: Correct COM port selected

### "Commands not executing"
- ⚠️ **IMPORTANT:** The test script is **SEMI-AUTOMATED**
- Commands are logged but NOT actually sent (would require cartridge protocol implementation)
- **You must manually trigger commands** via C64 side or implement TEST_TERMINAL_MODE

### "RAM degradation detected"
- Check for memory leaks in `HandleOpenFile`/`HandleCloseFile`
- Verify `workingFile.close()` is called properly
- Check if `File` objects are stack-allocated (not heap)

---

## Next Steps After Testing

**If all tests PASS:**
- ✅ Mark D4 as COMPLETE in POST_SPRINT6_PLAN
- ✅ Document results in POST_SPRINT6_COMPLETION.md
- ✅ Archive test logs

**If any test FAILS:**
- ❌ Debug failing scenario
- ❌ Fix bug in CartApi.cpp
- ❌ Re-run tests
- ❌ Update KNOWN_ISSUES.md if unfixable

---

## Test Results Template

```markdown
## File I/O Core API Test Results

**Date:** 2025-12-26
**Tester:** [Your Name]
**Firmware:** v2.1.0 (POST-SPRINT6)
**Hardware:** Arduino Nano, SD card [size/type]

| Scenario | Status | Notes |
|----------|--------|-------|
| 1. Small File Read | ✅ PASS | All commands succeeded |
| 2. Large File Read | ✅ PASS | 8 chunks read correctly |
| 3. READ After CLOSE | ✅ PASS | Returned FILE_IS_NOT_OPENED as expected |
| 4. File Not Found | ✅ PASS | Returned error code (not SUCCESSFUL) |
| 5. OPEN Directory | ✅ PASS | Returned FILE_CANNOT_BE_OPENED |
| 6. Stress Test (50×) | ✅ PASS | RAM stable at 437 bytes (±0 drift) |

**Overall:** ✅ ALL TESTS PASSED
```

---

**Status:** Ready for execution
**Estimated time:** 15-20 minutes (manual verification)
