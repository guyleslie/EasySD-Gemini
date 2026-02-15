# Directory Lifecycle Invariant

**Sprint 5 - P1.2**
**Date:** 2025-12-26
**Purpose:** Prevent state drift between firmware CWD and DirFunction directory handle

---

## Core Principle

> **The SdFat firmware's current working directory (CWD) is the SINGLE SOURCE OF TRUTH.**
>
> `currentPath` is for **UI/debug display ONLY** - never use it to open directories.

---

## The Mandatory Pattern

After **EVERY** `sd.chdir()` operation, you **MUST** call `ResyncDirFromCwd()`:

```cpp
// CORRECT pattern:
sd.chdir(...)
ResyncDirFromCwd()  // Mandatory! No exceptions!
```

### What ResyncDirFromCwd() does:

1. **Close** current directory handle: `m_dirFile.close()`
2. **Open** current working directory: `m_dirFile.openCwd()` (no parameters in SdFat 2.x)
3. **Rewind** for clean iteration: `m_dirFile.rewind()`

---

## When to Close

**Always close `m_dirFile` before:**
- Changing directory with `sd.chdir()`
- Opening a new directory
- Exiting from a directory operation

**Implementation:** `ResyncDirFromCwd()` handles this automatically.

---

## When to Open with openCwd()

**After every `sd.chdir()` operation:**
- `ToRoot()` - changes to root directory
- `ChangeDirectory()` - changes to child directory
- `GoBack()` - changes to parent directory
- `Prepare()` - prepares current directory for iteration

**Never use:** `m_dirFile.open(currentPath)` ❌
**Always use:** `m_dirFile.openCwd()` ✅ (via ResyncDirFromCwd, no parameters in SdFat 2.x)

---

## When to Rewind

**After opening a directory:**
- `ResyncDirFromCwd()` does this automatically
- Before starting iteration in `Prepare()`
- When manually resetting iteration position

---

## Directory Handle Validity

A directory handle (`m_dirFile`) is **VALID** when:
1. ✅ `m_dirFile.isOpen()` returns `true`
2. ✅ `m_dirFile.isDir()` returns `true`
3. ✅ It was opened with `openCwd(&sd)` after the last `sd.chdir()`
4. ✅ It points to the same directory as firmware's CWD

A directory handle is **INVALID** when:
1. ❌ It was opened with an absolute path string
2. ❌ `sd.chdir()` was called but `openCwd()` was not called afterward
3. ❌ It's still open from a previous directory

---

## Affected Functions

All functions that change directory state **MUST** follow the invariant:

| Function | Calls sd.chdir() | Must call ResyncDirFromCwd() |
|----------|------------------|------------------------------|
| `ToRoot()` | ✅ Yes | ✅ Yes - implemented |
| `ChangeDirectory()` | ✅ Yes | ✅ Yes - implemented |
| `GoBack()` | ✅ Yes | ✅ Yes - implemented |
| `Prepare()` | ❌ No | ✅ Yes - uses it to sync with CWD |

---

## Debug Assertions (DEBUG mode only)

In DEBUG builds, `ResyncDirFromCwd()` validates state after sync:

```cpp
#ifdef DEBUG
if (!m_dirFile.isOpen()) {
  Serial.println(F("DIR: ASSERT FAIL - dirFile not open after openCwd"));
}
if (!m_dirFile.isDir()) {
  Serial.println(F("DIR: ASSERT FAIL - dirFile is not a directory"));
}
#endif
```

These assertions catch violations immediately instead of causing random failures later.

---

## Anti-Patterns (NEVER DO THIS)

### ❌ Opening by absolute path
```cpp
// WRONG - violates the invariant
m_dirFile.open(currentPath);  // NO!
```

### ❌ Forgetting to resync after chdir
```cpp
// WRONG - creates state drift
sd.chdir(directory);
// Missing ResyncDirFromCwd()!
m_dirFile.rewind();  // Too late, handle is invalid
```

### ❌ Using currentPath as source of truth
```cpp
// WRONG - currentPath is UI only
if (!m_dirFile.open(currentPath)) { ... }  // NO!
```

---

## Correct Patterns

### ✅ Changing directory
```cpp
// Save state for rollback
char savedPath[64];
strcpy(savedPath, currentPath);

// Update UI path
strcat(currentPath, "/");
strcat(currentPath, directory);

// Change firmware CWD
if (!sd.chdir(directory)) {
  strcpy(currentPath, savedPath);  // Rollback
  return false;
}

// MANDATORY: Sync directory handle with firmware CWD
if (!ResyncDirFromCwd()) {
  strcpy(currentPath, savedPath);  // Rollback
  return false;
}
```

### ✅ Preparing for iteration
```cpp
// Don't open by path - sync with firmware CWD instead
if (!ResyncDirFromCwd()) {
  return;
}
// Now m_dirFile is valid and synced
```

---

## Testing the Invariant

**Manual tests that verify the invariant:**
1. Navigate: Root → A → B → .. → .. → Root (10x cycles)
2. List same directory 10x (verifies rewind works)
3. Navigate to empty directory
4. Navigate to single-file directory
5. Navigate to deep directory (3-4 levels)

**Success criteria:**
- ✅ No "open fail" when navigation succeeds
- ✅ No state drift (same operations produce same logs)
- ✅ RAM usage returns to baseline after 10+ cycles
- ✅ Directory counts remain consistent across rewinds

---

## Why This Matters

**Without this invariant:**
- Directory handle points to wrong directory
- "open fail, but navigation works" anomalies
- Random iteration failures
- State drift accumulates over time
- Debugging is extremely difficult

**With this invariant:**
- Deterministic behavior
- Firmware CWD and handle always synchronized
- Easy to debug (violations caught immediately in DEBUG mode)
- No mysterious failures

---

## References

- SdFat 2.x API: `openCwd()` is the canonical method for opening current working directory
- SdFat 2.3.0 examples/DirectoryFunctions/DirectoryFunctions.ino
- Sprint 5 implementation: `DirFunction.cpp`

---

**Last updated:** 2025-12-26 (Sprint 5 implementation)
