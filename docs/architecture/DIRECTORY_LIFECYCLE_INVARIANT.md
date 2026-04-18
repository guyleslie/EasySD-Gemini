# Directory Lifecycle Invariant

The SdFat firmware's current working directory (CWD) is the **single source of truth** for directory state. `currentPath` is a UI/debug display string only — never use it to open directories.

---

## Core Rule

After every `sd.chdir()` call, you must call `ResyncDirFromCwd()`:

```cpp
sd.chdir(dirname);
ResyncDirFromCwd();   // mandatory — no exceptions
```

`ResyncDirFromCwd()` does three things:
1. Closes the current directory handle (`m_dirFile.close()`)
2. Opens CWD (`m_dirFile.openCwd()` — no parameters, SdFat 2.x)
3. Rewinds for clean iteration (`m_dirFile.rewind()`)

---

## Affected Functions

| Function | Calls sd.chdir() | Calls ResyncDirFromCwd() |
|----------|-----------------|--------------------------|
| `ToRoot()` | yes | yes |
| `ChangeDirectory()` | yes | yes |
| `GoBack()` | yes | yes |
| `Prepare()` | no | yes (syncs with CWD) |

---

## Rules

- **Always** open via `m_dirFile.openCwd()` after chdir — never `m_dirFile.open(currentPath)`
- **Always** close `m_dirFile` before changing directory (ResyncDirFromCwd handles this)
- On `chdir()` failure, roll back `currentPath` to its previous value

Without this invariant, the directory handle drifts out of sync with CWD, causing iteration failures, stale listings, and hard-to-debug errors.

---

## Reference

Implementation: `Arduino/EasySD/DirFunction.cpp`
