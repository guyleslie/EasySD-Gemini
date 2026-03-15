# EasySD MultiLoad Plugin — Multi-Load Game Launcher

**Document Type:** Reference / User Guide
**Version:** 1.0
**Created:** 2026-03-15 (Sprint 14)
**Status:** Current

---

## 1. Purpose

The MultiLoad plugin enables classic C64 multi-load games to run from the SD card via EasySD.
These are games whose original floppy releases load additional program parts mid-game using
`LOAD "FILENAME",8,1` Kernal calls.

EasySD cannot emulate a full 1541 drive over the expansion port. Instead, the MultiLoad system
hooks the C64 Kernal LOAD vector ($0330/$0331) and intercepts every `JSR $FFD5` call that targets
device 8. Matching calls are served from the SD card at approximately 100× the speed of a real
floppy.

---

## 2. Components

The system consists of three parts, all assembled into a single `BOOT.PRG` binary:

### 2.1 RL_STUB — Kernal LOAD Trampoline (`$033C`, 20 bytes)

A small trampoline patched into the Kernal LOAD vector.
When the game calls `JSR $FFD5`, the C64 dispatches to `$033C` instead of the real Kernal
routine.

```
RL_STUB ($033C):
  PHA
  LDA $01 → STA RL_SAVED_01          ; save game's memory config
  LDA #$35 → STA $01                 ; bank: Kernal ROM → RAM, I/O active
  JSR RL_HANDLER                     ; call main handler at $E800
  LDA RL_SAVED_01 → STA $01          ; restore game's memory config
  PLA
  RTS                                ; return to Kernal dispatch
```

**Rationale for $01=$35:**
- `$35` = `00110101` → HIRAM=0 (Kernal ROM hidden, $E000-$FFFF is RAM), CHAREN=1 (I/O active)
- The handler at $E800 is only reachable with this banking; I/O must stay active for CartLib

**Location:** reuses the `FILE_PATH_BUF` area at `$033C`.
This is safe: during game execution no file-path lookups happen via the menu, so the two
uses never overlap.

### 2.2 RL_HANDLER — Main Hook Handler (`$E800`, ~400 bytes)

The resident handler that performs the actual SD file load.
It is physically stored in the `BOOT.PRG` binary and copied to `$E800` RAM by `RL_INSTALL`.
Writes to this region always go to the underlying RAM regardless of the `$01` banking register.

**Data areas inside the handler image:**

| Address    | Symbol         | Size    | Purpose                            |
|------------|----------------|---------|------------------------------------|
| `$E800`    | `RL_HANDLER`   | —       | Entry point                        |
| `$E840`    | `RL_DIR_PATH`  | 64 B    | Reserved for future chdir support  |
| `$E880`    | `RL_FNAME_BUF` | 36 B    | Assembled filename (name + `.PRG`) |
| `$E8A4`    | `RL_FILEINFO_BUF` | 32 B | FAT directory entry buffer         |
| `$E8C4`    | `RL_HDR_BUF`   | 256 B   | First-page read buffer             |

**Handler execution flow:**

```
RL_HANDLER (entry):
  LDA KERNAL_DEVICE_NUMBER
  CMP #8                         → if ≠ 8: JMP (RL_ORIG_VEC) [pass-through]

rl_main:
  JSR IRQ_StartTalking            ; wake Arduino; Arduino stays in game directory

  Build filename:
    copy KERNAL_FILENAME_LENGTH bytes from (KERNAL_FILENAME_LOW) → RL_FNAME_BUF
    if last 4 bytes ≠ ".PRG": append ".PRG\0"

  Open file:
    JSR IRQ_SetName               ; filename = RL_FNAME_BUF
    JSR IRQ_OpenFile              ; flags = read ($01)
    error → JSR IRQ_EndTalking, SEC, RTS

  Get 32-bit file size from FAT entry:
    JSR IRQ_GetInfoForFile → RL_FILEINFO_BUF
    store bytes 28-31 → ZP_LOADFILE_API_SIZE0..SIZE3

  Read first page (256 bytes) → RL_HDR_BUF:
    bytes 0-1  = PRG load address (little-endian)
    bytes 2-255 = first 254 data bytes

  Copy first 254 data bytes to load address ($8B/$8C):
    if file_size ≤ 255: copy (size-2) bytes, done
    if file_size ≥ 256: copy 254 bytes,
      then JSR LoadFileBySize (target=load_addr+254, SKIP=$100)

  Compute end address = load_addr + file_size - 2:
    X = end_lo, Y = end_hi

  JSR IRQ_CloseFile
  JSR IRQ_EndTalking
  CLC                             ; Kernal convention: C=0 success
  RTS                             ; X=end_lo, Y=end_hi per Kernal
```

**Kernal return convention:**
On success, carry=0, X=end address low byte, Y=end address high byte.
BASIC and other callers (e.g. `SYS`) update their own page-end pointers ($2D/$2E) from X/Y.

**Pass-through for non-device-8 loads:**
`JMP (RL_ORIG_VEC)` — the original Kernal LOAD vector is preserved at `$035C` and used here.
Tape loads (device 1) and other devices route through the original Kernal unchanged.

### 2.3 RL_INSTALL — One-Time Installer (runs in `$C000+` context)

Called once by `BOOT.PRG` before jumping to the game. Does not require an active EasySD session.

```
RL_INSTALL:
  1. Copy RL_STUB image  → $033C   (Y-loop, ≤ 32 bytes)
  2. Copy RL_HANDLER image → $E800 (multi-page copy via ZP pointers $8B-$8E)
  3. Backup $0330/$0331 → RL_ORIG_VEC ($035C)
  4. Patch $0330 = <RL_STUB, $0331 = >RL_STUB
  All registers preserved (A/X/Y pushed/popped).
```

---

## 3. Memory Layout

### 3.1 ResidentLoader Area (during game execution)

| Address        | Symbol         | Content                          |
|----------------|----------------|----------------------------------|
| `$0330/$0331`  | —              | Kernal LOAD vector, patched → `$033C` |
| `$033C–$034F`  | `RL_STUB`      | 20-byte trampoline code          |
| `$035C–$035D`  | `RL_ORIG_VEC`  | Backup of original `$0330/$0331` |
| `$035E`        | `RL_SAVED_01`  | Saved `$01` value during hook    |
| `$E800–$E9FF`  | `RL_HANDLER`   | Handler code + data areas (~400 B) |

**Note:** `$033C–$035F` is the same region used as `FILE_PATH_BUF` by the menu / plugins.
The two uses are mutually exclusive (game execution ↔ menu navigation) and therefore safe.

### 3.2 BOOT.PRG Plugin Code (`$C000+`)

The MultiLoad plugin code itself lives in the standard plugin range:

| Address Range   | Content                                              |
|-----------------|------------------------------------------------------|
| `$C000`         | `JMP MAIN` entry point                               |
| `$C001–$C0xx`   | FIRST_PART_NAME string, MAIN, ML_SAVESTATE/RESTORESTATE |
| `$C0xx–$C2xx`   | ML_FILEINFO_BUF (32 B), ML_HDRBUF (256 B)           |
| `$C2xx–$C8xx`   | RL_STUB image, RL_HANDLER image, RL_INSTALL, CartLib |

The plugin includes a compile-time overflow guard:
```asm
.if * > $DF00
    .error "MultiLoad plugin overflow: exceeds $DF00 (I/O space)"
.endif
```

---

## 4. BOOT.PRG Boot Flow

```
User navigates to game directory in EasySD menu
  └─ Selects BOOT.PRG
       ↓
Menu loads BOOT.PRG to $C000, JMPs to $C000

BOOT.PRG:
  1. JSR ML_SAVESTATE            save VIC/$01 for error-path cleanup
  2. JSR RL_INSTALL              copy stub + handler, patch $0330
  3. JSR IRQ_StartTalking        wake Arduino (already in game directory)
  4. IRQ_SetName (FIRST_PART_NAME)
     IRQ_OpenFile
  5. IRQ_GetInfoForFile          get 32-bit file size
  6. IRQ_ReadFileNoCallback      read first 256 bytes → ML_HDRBUF
  7. Copy first 254 data bytes to PRG load address
  8. LoadFileBySize (remainder)  if file_size ≥ 256
  9. IRQ_CloseFile / IRQ_EndTalking
  10. JMP (load_address)         ← game starts; never returns to menu

If any step fails:
  IRQ_EndTalking → ML_RESTORESTATE → IRQ_ExitToMenu
```

**After step 10:** The resident hook is active. All `JSR $FFD5` calls from the game code that
target device 8 are silently intercepted and served from the SD card.

---

## 5. SD Card Directory Structure

No special format is required. Game files must be placed in a single flat directory on the SD card:

```
/GAMES/MYGAME/
  BOOT.PRG          ← user selects this from EasySD menu
  LOADER.PRG        ← FIRST_PART_NAME (the first part to load automatically)
  LEVEL1.PRG        ← game does: LOAD "LEVEL1",8,1
  LEVEL2.PRG        ← game does: LOAD "LEVEL2",8,1
  TITLE.PRG         ← game does: LOAD "TITLE",8
  …
```

**Filename matching:**
- `LOAD "LEVEL1",8` → hook searches for `LEVEL1.PRG`
- `LOAD "LEVEL1.PRG",8` → hook searches for `LEVEL1.PRG` (already has extension)
- Extension check: last four characters checked for `.PRG` (case-sensitive, uppercase)

---

## 6. Game-Specific Configuration

Edit `FIRST_PART_NAME` in `MultiLoad.s` before building:

```asm
FIRST_PART_NAME:
    .text "LOADER"          ; ← change to the first part's filename (no .PRG)
FIRST_PART_LEN = * - FIRST_PART_NAME
```

Then rebuild:

```bash
python Tools/build.py multiload
```

Output: `EasySD/build/plugins/bootplugin.prg`
Copy to the game directory on the SD card and rename to `BOOT.PRG`.

---

## 7. Build System Integration

| Target | Command | Output |
|--------|---------|--------|
| Build BOOT.PRG only | `python Tools/build.py multiload` | `build/plugins/bootplugin.prg` |
| Build all plugins | `python Tools/build.py plugins` | all `.prg` in `build/plugins/` |
| Full release build | `python Tools/build.py release` | all artifacts |

`bootplugin` is entry index 7 in `PLUGIN_MATRIX` (defined in `Tools/build.py`).
All plugin builds use the `--long-branch` flag so 64tass automatically expands any
branch instructions that exceed the ±127-byte range.

---

## 8. V1 Limitations

| Limitation | Detail | Planned Fix |
|------------|--------|-------------|
| **CartLib at $C000+** | The handler calls CartLib routines in `$C000+` RAM. If a game part loads into `$C000+` and overwrites CartLib, subsequent LOAD hooks will crash. | V2: embed a mini-CartLib inside the handler at `$E800`. |
| **SA=0 (MEMUSS) not supported** | Secondary address 0 means "load to address in $C3/$C4 (MEMUSS)", ignoring the PRG header. V1 always uses the PRG header address. This is rarely needed by multi-load games. | V2: check SA in hook and branch accordingly. |
| **No chdir per LOAD call** | The Arduino stays in the game directory from when the user navigated there; no per-LOAD `chdir`. Works because the user selects BOOT.PRG from inside the game directory. | V2: issue COMMAND_CHANGE_DIR before each file open. |
| **Device 8 only** | Non-device-8 LOADs pass through to the original Kernal LOAD; other devices work normally. This is a feature, not a limitation. | — |

---

## 9. Key Source Files

| File | Purpose |
|------|---------|
| `EasySD/Loader/ResidentLoader.s` | RL_STUB + RL_HANDLER images + RL_INSTALL subroutine |
| `EasySD/Loader/Bridges/MultiLoad/MultiLoad.s` | BOOT.PRG plugin entry point and first-part loader |
| `EasySD/Loader/Common/System.inc` | `RL_STUB`, `RL_ORIG_VEC`, `RL_SAVED_01`, `RL_DIR_PATH`, `RL_FNAME_BUF`, `RL_FILEINFO_BUF`, `RL_HDR_BUF` constants |
| `EasySD/Loader/CartZpMap.inc` | `$033C-$035F` dual-use annotation; `$8B-$8C` handler scratch |

---

## 10. Technical Notes

**Why writes to $E800 always go to RAM:**
On the C64, the CPU's write line always reaches the underlying RAM regardless of the `$01`
banking register. ROM overlays only affect reads. `RL_INSTALL` therefore copies the handler
with the normal `$01=$37` configuration and no banking switch is needed during installation.

**Why $01=$35 in the hook:**
The `RL_HANDLER` code lives at `$E800`, which is normally under the Kernal ROM. Setting
`$01=$35` (HIRAM=0) makes the CPU read from RAM at that address instead of ROM. At the same
time, `CHAREN=1` is preserved so I/O at `$D000-$DFFF` remains active — required by CartLib.

**Why the PRG header reading strategy:**
CartLib data transfers work in 256-byte pages. Reading exactly 2 bytes for the header is not
directly supported. The handler reads a full 256-byte first page: bytes 0-1 are the PRG load
address, bytes 2-255 are the first 254 data bytes. Remaining data is streamed via
`LoadFileBySize` with `SKIP=$100` (skip the first 256 bytes that were already read).

**Kernal state during the hook:**
`KERNAL_FILENAME_LENGTH` ($B7), `KERNAL_FILENAME_LOW` ($BB), `KERNAL_FILENAME_HIGH` ($BC),
and `KERNAL_DEVICE_NUMBER` ($BA) are set by the Kernal's own `SETNAM`/`SETLFS` routines before
`JSR $FFD5` is called. The hook reads these directly, replicating the Kernal's own LOAD logic.
