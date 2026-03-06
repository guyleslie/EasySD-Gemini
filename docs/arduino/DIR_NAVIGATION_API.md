# Directory Navigation API - Sprint 1 Changes

## Overview

This document describes the changes made to the directory navigation system in Sprint 1 of the EasySD Architecture Refactoring project. The primary goal was to implement firmware-centric state management with proper error handling and rollback support.

## DirFunction Class Changes

### Modified Methods

#### `bool ChangeDirectory(char* directory)`

**Previous Signature:**
```cpp
void ChangeDirectory(char* directory)
```

**New Signature:**
```cpp
bool ChangeDirectory(char* directory)
```

**Changes:**
- **Returns:** `bool` - `true` on success, `false` on failure
- **Validation:** Checks for empty directory name and path buffer overflow
- **Rollback:** Saves current state before attempting change; restores on failure
- **Behavior:** Only updates `InSubDir` and `pathDepth` if `sd.chdir()` succeeds

**Example Usage:**
```cpp
if (dirFunc.ChangeDirectory("GAMES")) {
    // Successfully changed to GAMES directory
    dirFunc.Prepare();
} else {
    // Failed - state remains unchanged
    Serial.println("Directory not found");
}
```

---

#### `bool GoBack()`

**Previous Signature:**
```cpp
void GoBack()
```

**New Signature:**
```cpp
bool GoBack()
```

**Changes:**
- **Returns:** `bool` - `true` on success, `false` if already at root or operation fails
- **Root Detection:** Returns `false` immediately if `pathDepth == 0`
- **Rollback:** Saves current state before attempting navigation; restores on failure
- **Behavior:** Properly decrements `pathDepth` and updates `InSubDir` only on success

**Example Usage:**
```cpp
if (dirFunc.GoBack()) {
    // Successfully navigated to parent
    dirFunc.Prepare();
} else {
    // Already at root or operation failed
    Serial.println("Cannot go back");
}
```

---

### New Methods

#### `bool ChangeDirectoryBasename(const char* basename)`

**Purpose:** Navigate using only a basename (no path separators allowed)

**Parameters:**
- `basename` - Directory name without path separators (e.g., "GAMES", not "/GAMES")

**Special Handling:**
- **".." Detection:** Automatically calls `GoBack()` if basename is ".."
- **Validation:** Rejects basenames containing '/' character
- **Empty Check:** Returns `false` for `NULL` or empty string

**Returns:**
- `true` - Successfully changed directory
- `false` - Invalid basename, directory not found, or operation failed

**Example Usage:**
```cpp
// Navigate to subdirectory
if (dirFunc.ChangeDirectoryBasename("GAMES")) {
    Serial.println("Entered GAMES");
}

// Navigate to parent
if (dirFunc.ChangeDirectoryBasename("..")) {
    Serial.println("Went back to parent");
}

// Invalid - contains path separator
if (!dirFunc.ChangeDirectoryBasename("GAMES/ARCADE")) {
    Serial.println("ERROR: Use basename only!");
}
```

**Why This Method:**
This method enforces the firmware-centric architecture principle: the C64 menu only sends basenames, never full paths. This prevents state desynchronization between C64 and Arduino.

---

#### `const char* GetCurrentPath() const`

**Purpose:** Query the current working directory path

**Returns:** Pointer to the internal `currentPath` string (null-terminated)

**Example Usage:**
```cpp
Serial.print("Current directory: ");
Serial.println(dirFunc.GetCurrentPath());
// Output: /GAMES/ARCADE/
```

**Note:** Returns a pointer to internal storage. Do not modify the returned string.

---

#### `void ForceReset()`

**Purpose:** Emergency reset to root directory with full re-initialization

**Behavior:**
1. Calls `ToRoot()` to return to root directory
2. Calls `Prepare()` to rebuild directory listing
3. Logs reset operation in DEBUG mode

**Example Usage:**
```cpp
// After error or timeout
dirFunc.ForceReset();
Serial.println("Reset to root");
```

**Use Cases:**
- Recovery from corrupted state
- Timeout or communication error recovery
- User-initiated reset command

---

#### `void CloseDirHandle()`

**Purpose:** Close the internal directory file handle (`m_dirFile`) before SD reinitialization.

**When to use:** Must be called before `sd.begin()` during error recovery. Open directory handles become invalid after SD reinit.

**Example Usage:**
```cpp
// SD error recovery pattern (see recoverSD() in EasySD.ino)
dirFunc.CloseDirHandle();
delay(50);
sd.begin(chipSelect, SPI_QUARTER_SPEED);
dirFunc.ForceReset();
```

---

## CartApi Changes

### HandleChangeDirectory()

**Location:** `CartApi.cpp:452-507`

**Major Changes:**

1. **Input Validation**
   - Checks for empty directory name (`fileNameLength == 0`)
   - Returns `INVALID_ARGUMENT` error if empty
   - Ensures null termination of filename string

2. **Enhanced Error Handling**
   - Calls `dirFunc.ChangeDirectoryBasename()` instead of separate logic
   - Only calls `dirFunc.Prepare()` if navigation succeeds
   - Returns `DIR_NOT_FOUND` on failure (instead of always `SUCCESSFUL`)

3. **Enhanced Logging**
   - Logs current path before and after operation
   - Logs new directory count on success
   - Logs failure reason and unchanged path on error

**Error Codes:**
- `SUCCESSFUL` (0x80) - Directory changed successfully
- `INVALID_ARGUMENT` (0x09) - Empty directory name provided
- `DIR_NOT_FOUND` (0x0B) - Directory doesn't exist or navigation failed

**Previous Behavior (BUG):**
```cpp
// OLD: Always returned SUCCESSFUL even if navigation failed!
dirFunc.ChangeDirectory(fileName);  // void return, no error check
dirFunc.Prepare();                  // Always called
HandleResponse(SUCCESSFUL, 1);      // Always successful!
```

**New Behavior (FIXED):**
```cpp
// NEW: Proper error handling with state safety
bool success = dirFunc.ChangeDirectoryBasename(fileName);
if (success) {
    dirFunc.Prepare();  // Only if successful
    HandleResponse(SUCCESSFUL, 1);
} else {
    HandleResponse(DIR_NOT_FOUND, 1);  // Report failure
}
```

---

## Testing Commands (Serial Monitor @ 57600 baud)

### Command 'p' - Print Current State

Displays the current directory state without making changes.

**Usage:** Type `p` and press Enter

**Output:**
```
=== Current State ===
Path: /GAMES/
Depth: 1
InSubDir: 1
Count: 15
```

---

### Command 'd' - Directory Navigation Test

Interactive test for entering directories or going back to parent.

**Usage:**
1. Type `d` and press Enter
2. When prompted, type directory name (or "..")
3. Press Enter

**Example Session:**
```
=== Directory Navigation Test ===
Current path: /
Path depth: 0
Enter directory name (or .. to go back):
GAMES
Attempting to navigate to: GAMES
SUCCESS!
New path: /GAMES/
Item count: 15
```

---

### Command 'r' - Reset to Root

Forces reset to root directory.

**Usage:** Type `r` and press Enter

**Output:**
```
=== Reset to Root ===
Path: /
Count: 8
```

---

## Testing Checklist

Run these tests in order via Serial Monitor (57600 baud):

### Test 1: Print Current State
- **Command:** `p`
- **Expected:** Path="/", Depth=0, Count=(number of root items)

### Test 2: Enter Valid Subdirectory
- **Command:** `d`
- **Input:** Name of existing subdirectory (e.g., "GAMES")
- **Expected:** SUCCESS, path="/GAMES/", depth=1

### Test 3: Navigate Back with ".."
- **Command:** `d`
- **Input:** `..`
- **Expected:** SUCCESS, path="/", depth=0

### Test 4: Try Invalid Directory
- **Command:** `d`
- **Input:** "NOTEXIST"
- **Expected:** FAILED, path unchanged

### Test 5: Nested Navigation
- **Sequence:**
  1. Enter dir1 → SUCCESS
  2. Enter dir2 → SUCCESS
  3. `..` → SUCCESS (back to dir1)
  4. `..` → SUCCESS (back to root)
- **Expected:** All succeed, end at root

### Test 6: Force Reset After Deep Navigation
- **Sequence:**
  1. Navigate deep into directories
  2. **Command:** `r`
- **Expected:** Path="/", depth=0

### Test 7: Path Overflow Protection
- **Input:** Very long directory name (>60 characters)
- **Expected:** FAILED, path unchanged, no crash

---

## State Consistency Guarantees

### Atomicity
All directory operations are atomic:
- **Success:** State updated completely
- **Failure:** State remains unchanged (rollback)

### No Partial Updates
Previous bugs where `pathDepth` or `InSubDir` could be inconsistent are now fixed:
```cpp
// OLD BUG: pathDepth incremented even if chdir failed
pathDepth++;
if (!sd.chdir(path)) {
    // BUG: pathDepth already incremented!
}

// NEW FIX: Only update on success
if (sd.chdir(path)) {
    pathDepth++;  // Only if successful
    return true;
}
return false;  // No state changes
```

### Error Recovery
All methods support safe error recovery:
- Failed operations don't corrupt state
- `ForceReset()` available for emergency recovery
- Rollback prevents "half-changed" states

---

## Integration with C64 Menu (Future: Sprint 2)

The enhanced API prepares for Sprint 2 changes where:

1. **C64 Removes DIRSTACK**
   - No more local path tracking on C64
   - C64 trusts firmware state completely

2. **C64 Sends Only Basenames**
   - Menu sends "GAMES", not "/GAMES"
   - Menu sends ".." for parent navigation
   - Firmware validates and navigates

3. **Error Handling on C64**
   - C64 checks carry flag from `IRQ_ChangeDirectory`
   - Carry set → stay in same directory, show error
   - Carry clear → refresh directory listing

**Example C64 Assembly (Sprint 2):**
```assembly
; Current row has directory name
JSR GETCURRENTROW           ; X = selected row
LDA NAMESLO, X
TAX
LDA NAMESHI, X
TAY                         ; X/Y = pointer to name

JSR IRQ_SetNameZ            ; Set name for next command
JSR IRQ_ChangeDirectory     ; Firmware navigates
BCS NAVFAILED               ; Carry set = failed

; Success - read new directory
JSR IRQ_ReadDirectoryNC
JMP DISPLAY_MENU

NAVFAILED:
; Show error, stay in current directory
JSR SHOW_ERROR
JMP INPUT_GET
```

---

## Files Modified in Sprint 1

1. **DirFunction.h** - Updated method signatures
   - `bool ChangeDirectory(char*)` - was `void`
   - `bool GoBack()` - was `void`
   - Added 3 new methods

2. **DirFunction.cpp** - Implementation (~180 lines changed/added)
   - Modified `ChangeDirectory()` with rollback
   - Modified `GoBack()` with rollback
   - Added `ChangeDirectoryBasename()`
   - Added `GetCurrentPath()`
   - Added `ForceReset()`

3. **CartApi.cpp** - Updated `HandleChangeDirectory()` (~55 lines)
   - Added input validation
   - Added error handling with proper return codes
   - Enhanced debug logging

4. **EasySD.ino** - Added test commands (~70 lines)
   - Added 'd', 'r', 'p' test commands
   - Added 3 test functions

5. **DIR_NAVIGATION_API.md** - This documentation file

---

## Backward Compatibility

### Firmware API
The C64 protocol remains unchanged:
- `COMMAND_CHANGE_DIR` (11) - Still uses same command byte
- Arguments format unchanged
- Only internal implementation improved

### Existing Code
All existing code using `dirFunc.ChangeDirectory()` or `dirFunc.GoBack()` will need minor updates:
```cpp
// OLD CODE (still compiles but ignores errors):
dirFunc.ChangeDirectory("GAMES");

// NEW CODE (recommended):
if (dirFunc.ChangeDirectory("GAMES")) {
    // Handle success
} else {
    // Handle error
}
```

**Migration:** Add error checking where critical; ignore return value where errors are acceptable.

---

## Known Limitations

1. **Path Length:** Maximum path is 64 characters (inherited from original design)
2. **No Absolute Paths:** `ChangeDirectoryBasename()` rejects paths with '/'
3. **Sequential Only:** Cannot navigate multiple levels in one call (by design)

---

## Next Steps (Sprint 2+)

1. **Sprint 2:** Refactor C64 menu to use basename-only navigation
2. **Sprint 3:** Update plugins to use new error handling
3. **Sprint 4:** Integration testing and performance optimization

---

**Document Version:** 1.0
**Date:** 2025-12-23
**Sprint:** 1 (Firmware Foundation)
**Status:** Complete
