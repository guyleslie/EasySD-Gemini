# EasySD Last-Directory Removal Decision

## Status

**IMPLEMENTED** (as of firmware build 2026-04-12).

This decision has been completed. The firmware now:

- does NOT save or restore directory state via EEPROM
- boots the menu from root unconditionally
- does not use SD-card temp files for directory state
- preserves all 1 KB of MCU internal EEPROM for future use

This was a product and reliability decision, not only code cleanup.

## Executive Decision

The recommended direction is:

1. remove active `last dir` save and restore behavior from the firmware
2. keep directory state only in RAM for the current powered session
3. always boot the menu from root
4. do not write directory history to MCU internal EEPROM
5. do not create an SD-card temp-state mechanism as a replacement

## Why Removal Is Recommended

### 1. The feature is not core to EasySD's job

EasySD's core responsibilities are:

- boot reliably on real C64 hardware
- provide stable directory browsing
- support file loading and plugin launch
- keep the Arduino and C64 protocol state clean

Automatic restore of the previously visited directory is only a convenience feature.

It is not required for:

- menu startup
- normal browsing
- plugin loading
- MultiLoad path restore during runtime

If a feature is not essential, it should not be allowed to complicate startup or consume persistent storage endurance.

### 2. Real-hardware startup reliability is more important than resume convenience

The current code path already shows that last-directory persistence touches a timing-sensitive part of the system.

Current active behavior in the firmware:

- successful `COMMAND_CHANGE_DIR` stores the current path in RAM shadow state
- menu transfer later flushes that RAM shadow to EEPROM
- menu transfer then calls restore before entering the command loop

This means persistence is not passive storage. It actively participates in the menu startup lifecycle.

That is the wrong tradeoff for EasySD:

- startup must be deterministic
- root boot is easy to reason about
- hidden restore behavior is harder to debug on real hardware

### 3. EEPROM endurance should be spent only on truly important state

The ATmega328P internal EEPROM is finite-endurance storage.

Typical Arduino documentation guidance is approximately:

- around 100,000 write/erase cycles per cell
- write operations are slow compared to RAM operations

Even if the implementation is technically correct, repeatedly storing a frequently changing UI browsing path is not a good use of EEPROM lifetime.

This is especially true because the current record has hot cells that change on every save, for example:

- the committed marker
- path length
- CRC bytes

Those cells wear much faster than the rest of the record.

EasySD is intended to be used many times over a long period. A non-essential convenience feature should not consume endurance budget from the MCU's persistent storage.

### 4. SD-card temp storage is not a better replacement

Using an SD-card file such as `/TEMP/LASTDIR.TXT` is not recommended as a replacement.

It avoids EEPROM wear, but creates new problems:

- requires extra file open/write/sync/close operations
- adds FAT update and power-loss failure windows
- couples state to the currently inserted SD card
- increases filesystem complexity for a non-essential feature
- still does not justify startup complexity if auto-restore is used

If the feature is unnecessary, the clean answer is to remove it, not move it to a different storage medium.

### 5. MultiLoad does not need power-cycle last-directory persistence

EasySD already has explicit runtime path mechanisms for controlled navigation.

Relevant current code paths:

- `COMMAND_GET_PATH` returns the active path from Arduino runtime state
- `COMMAND_GOTO_PATH` restores a requested path explicitly from the C64 side
- `DirFunction::NavigateToPath()` performs authoritative runtime navigation

This means MultiLoad-style flows can use explicit runtime path restore without relying on boot-time EEPROM state.

So last-directory persistence is not required as infrastructure for MultiLoad.

## Current Active Removal Scope

The following active code paths are the ones that should be removed or neutralized.

### Arduino side: state fields

File:

- `Arduino/EasySD/CartApi.h`

Current fields:

- `bool lastDirDirty;`
- `char pendingLastDir[64];`

Recommended action:

- remove both fields entirely

### Arduino side: persistence helpers

File:

- `Arduino/EasySD/CartApi.cpp`

Current helpers:

- `SaveLastDirRecord(const char* path)`
- `RestoreLastDir()`
- CRC helper and EEPROM record layout constants used only by last-dir persistence

Recommended action:

- remove these helpers from active firmware
- remove the related record-layout constants if they are not used elsewhere
- remove the related CRC helper if it becomes unused

### Arduino side: init behavior

File:

- `Arduino/EasySD/CartApi.cpp`

Current init still clears last-dir RAM shadow state:

- `lastDirDirty = false;`
- `pendingLastDir[0] = '\0';`

Recommended action:

- remove these lines as part of field removal

### Arduino side: directory-change side effect

File:

- `Arduino/EasySD/CartApi.cpp`

Current behavior after successful directory change:

- `dirFunc.Prepare();`
- copy `dirFunc.currentPath` into `pendingLastDir`
- set `lastDirDirty = true`

Recommended action:

- keep `dirFunc.Prepare();`
- remove the RAM-shadow copy
- remove the dirty-flag update
- leave command response behavior unchanged

### Arduino side: menu-transfer side effect

File:

- `Arduino/EasySD/CartApi.cpp`

Current behavior near the end of `TransferMenu()`:

- flush pending last-dir RAM shadow to EEPROM
- call `RestoreLastDir()`

Recommended action:

- remove both actions entirely
- after menu transfer, go straight to command-loop readiness

### Documentation cleanup targets

The following documents should be updated to avoid stale architecture claims:

- `docs/architecture/EEPROM_ARCHITECTURE.md`
- `docs/architecture/LAST_DIR_PERSISTENCE_REDESIGN.md`
- any testing or roadmap document that still describes active save/restore behavior

## What Should Remain

The following behavior should remain unchanged:

1. `DirFunction` runtime navigation
2. current-path reporting with `COMMAND_GET_PATH`
3. explicit path restore with `COMMAND_GOTO_PATH`
4. root-based startup
5. session-local directory browsing during one powered run

This preserves all core file browser behavior while removing only the persistent resume feature.

## Why This Is the Cleanest Product Model

After removal, the system model becomes simple:

- boot: root
- browse: runtime only
- reset or power cycle: root again

That model is easy to explain, easy to test, and easy to debug.

It also matches the embedded-systems rule that persistent storage should be reserved for settings that are actually worth their write cost and failure surface.

`last dir` does not meet that bar for EasySD.

## Acceptance Criteria For Removal

Removal can be considered complete when all of the following are true:

1. No active firmware code writes browsing path state to MCU internal EEPROM.
2. No active firmware code attempts to restore last directory automatically.
3. `COMMAND_CHANGE_DIR` still behaves exactly as before for the current session.
4. Cold boot and menu reload always begin from root.
5. MultiLoad and explicit runtime path operations still work normally.
6. Documentation no longer claims that last-directory persistence is an active feature.

## Final Recommendation

For EasySD, the professional recommendation is:

- remove last-directory persistence completely
- do not replace it with SD temp-file persistence
- keep explicit runtime path features only

This improves reliability, reduces hidden behavior, avoids unnecessary EEPROM wear, and keeps the system aligned with its actual core responsibilities.