# Directory Navigation API Reference

**File:** `Arduino/EasySD/DirFunction.h` / `DirFunction.cpp`
**Last updated:** 2026-04-18

---

## Overview

`DirFunction` manages all directory state on the Arduino side. It is the **single source of truth** for the current working directory. The C64 menu never maintains its own path state — it sends only basenames and relies entirely on the Arduino to track where it is.

### Design principles

- **Atomic operations:** every navigation method either succeeds fully or rolls back to the previous state — no partial updates
- **Firmware CWD is authoritative:** `currentPath` is a debug/UI string only; the SdFat library's internal CWD drives all actual navigation
- **Resync after every chdir:** `ResyncDirFromCwd()` is called after every `sd.chdir()` to keep `m_dirFile` in sync

---

## State variables (public)

| Variable | Type | Description |
|----------|------|-------------|
| `currentPath[64]` | `char[]` | Null-terminated string of the current path (e.g. `/GAMES/`). UI/debug use only — not used for actual navigation. Max usable path: 63 characters. |
| `pathDepth` | `uint8_t` | Number of directory levels below root. 0 = root, 1 = one level deep, etc. No hardcoded maximum — the path buffer is the practical limit. |
| `InSubDir` | `int` | 1 if not at root, 0 at root. |
| `count` | `unsigned int` | Number of entries in the current directory (includes `..` when in a subdirectory). |
| `currentIndex` | `unsigned int` | Current iteration position. |
| `IsDirectory` | `int` | Set by `Iterate()`: 1 if the last iterated entry is a directory. |
| `IsFinished` | `int` | Set by `Iterate()`: 1 when all entries have been iterated. |
| `selected` | `unsigned int` | Menu cursor position tracking (get/set via `SetSelected`/`GetSelected`). |
| `currentFileName[32]` | `char[]` | Name of the last iterated entry (preview, may be truncated). |

---

## Methods

### `void ToRoot()`

Resets to the root directory unconditionally.

- Clears `currentPath` to `"/"`
- Sets `pathDepth = 0`, `InSubDir = 0`
- Calls `sd.chdir()` (no arguments = root)
- Calls `ResyncDirFromCwd()`

---

### `void ReInit()`

Alias for `ToRoot()`. Used at startup.

---

### `bool ChangeDirectory(char* directory)`

Navigate into a subdirectory relative to the current directory.

**Parameters:** `directory` — bare name, no slashes (e.g. `"GAMES"`)

**Returns:** `true` on success, `false` on failure (state unchanged)

**Behaviour:**
1. Validates non-empty name and path buffer space (`currentPath + name + 2 <= 64`)
2. Saves current state for rollback
3. Appends name to `currentPath`
4. Calls `sd.chdir(directory)` — relative, not absolute
5. Calls `ResyncDirFromCwd()`
6. On success: increments `pathDepth`, sets `InSubDir = 1`
7. On any failure: rolls back to saved state

---

### `bool GoBack()`

Navigate to the parent directory.

**Returns:** `true` on success, `false` if already at root or operation fails (state unchanged)

**Behaviour:**
1. Returns `false` immediately if `pathDepth == 0`
2. Saves current state for rollback
3. Truncates `currentPath` to the parent path
4. If new path is root: calls `ToRoot()` and returns `true`
5. Otherwise: calls `sd.chdir(parentPath)` + `ResyncDirFromCwd()`
6. Decrements `pathDepth`; sets `InSubDir = 0` if back at root
7. On any failure: rolls back to saved state

---

### `bool ChangeDirectoryBasename(const char* basename)`

Primary entry point for C64-initiated navigation. Wraps `ChangeDirectory()` and `GoBack()`.

**Parameters:** `basename` — directory name or `".."`

**Returns:** `true` on success, `false` on failure

**Behaviour:**
- `basename == ".."` → calls `GoBack()`
- `basename` contains `'/'` → returns `false` (invalid)
- otherwise → calls `ChangeDirectory(basename)`

This is the method called by `CartApi.cpp::HandleChangeDirectory()`.

---

### `void Prepare()`

Count the entries in the current directory and prepare for iteration.

- Calls `ResyncDirFromCwd()` to ensure `m_dirFile` is in sync
- If `InSubDir == 1`: adds 1 to count (for the `..` entry)
- Iterates all entries with `file.openNext(&m_dirFile)`, counting non-hidden ones
- Rewinds `m_dirFile` ready for `Iterate()`

Call after any successful `ChangeDirectory()`, `GoBack()`, or `ForceReset()`.

---

### `int Iterate()`

Return the next directory entry. Call repeatedly after `Prepare()`.

**Returns:** 1 if an entry was read, 0 when done (sets `IsFinished = 1`)

**Behaviour:**
- If `InSubDir == 1` and `currentIndex == 0`: returns `..` as first entry (`IsDirectory = 1`)
- Otherwise: opens next file with `file.openNext(&m_dirFile)`, sets `currentFileName`, `IsDirectory`; skips hidden entries automatically

---

### `void Rewind()`

Reset iteration back to the beginning without re-counting. Rewinds `m_dirFile` and clears `currentIndex`, `IsDirectory`, `IsFinished`.

---

### `unsigned int GetCount()`

Returns `count` (set by `Prepare()`).

---

### `const char* GetCurrentPath() const`

Returns a read-only pointer to `currentPath`. Do not modify. Used for logging and the C64 menu header display.

---

### `void ForceReset()`

Emergency reset: calls `ToRoot()` then `Prepare()`. Use after SD error recovery.

---

### `void CloseDirHandle()`

Closes `m_dirFile` if open. Must be called before `sd.begin()` during SD error recovery — open file handles become invalid after SD reinitialisation.

**SD error recovery pattern:**
```cpp
dirFunc.CloseDirHandle();
delay(50);
sd.begin(chipSelect, SPI_HALF_SPEED);
dirFunc.ForceReset();
```

---

### `bool NavigateToPath(const char* absPath)`

Navigate from root to an absolute path, segment by segment. Used internally by
`LoadAndLaunchFile()` to restore the launch directory after a PRG transfer.

**Parameters:** `absPath` — absolute path starting with `/` (e.g. `"/GAMES/LEVEL1/"`)

**Returns:** `true` on success, `false` if any segment fails (resets to root on failure)

---

### `bool FindDirectoryNameByVisibleIndex(uint16_t visibleIndex, char* outName, size_t outSize)`

Look up a directory entry by its visible index (as seen by the C64 menu). Used by `COMMAND_CHANGE_DIR_INDEX`.

**Parameters:**
- `visibleIndex` — zero-based index matching the C64-visible entry order
- `outName` — output buffer (minimum 13 bytes)

**Returns:** `true` if found and entry is a directory (not `..`), `false` otherwise

---

### `bool FindByPrefix(const char* prefix, uint8_t len, char* outName, size_t outSize)`

Scan CWD for a non-hidden, non-directory file whose name starts with `prefix` (case-insensitive). Does not affect `Iterate()` state.

---

### `bool FindDirectoryByPrefix(const char* prefix, uint8_t len, char* outName, size_t outSize)`

Same as `FindByPrefix` but matches directories only.

---

### `void SetSelected(unsigned int)` / `unsigned int GetSelected()`

Get/set the `selected` index (menu cursor position tracking).

---

### `bool ResyncDirFromCwd()` *(protected)*

Synchronises `m_dirFile` with the SdFat library's current working directory.

1. Closes `m_dirFile` if open
2. Opens CWD with `m_dirFile.openCwd()` (SdFat 2.x canonical method)
3. Rewinds for clean iteration

Called internally after every `sd.chdir()`. Not called directly by CartApi.

---

## CartApi integration

`CartApi.cpp::HandleChangeDirectory()` is the only caller from the C64 protocol layer.

| Return code | Value | Meaning |
|-------------|-------|---------|
| `SUCCESSFUL` | `0x80` | Directory changed, `Prepare()` called |
| `INVALID_ARGUMENT` | `0x09` | Empty directory name |
| `DIR_NOT_FOUND` | `0x0B` | Navigation failed (directory doesn't exist or SD error) |

---

## Path depth limit

There is **no hardcoded maximum depth**. The practical limit is the `currentPath[64]` buffer:

| Folder name length | Max levels |
|--------------------|-----------|
| 8 characters (FAT max) | ~7 |
| 4 characters | ~12 |
| 1 character | ~31 |

With 8-character names: `/DIRNAME1/DIRNAME2/.../DIRNAME7` = 63 characters.

---

## Serial test commands (57600 baud)

| Command | Action |
|---------|--------|
| `p` | Print current path, depth, count |
| `d` | Interactive directory navigation (prompts for name or `..`) |
| `r` | Force reset to root |
