# EasySD MultiLoad Plugin — Multi-Load Game Launcher

**Document Type:** Reference / User Guide
**Version:** 3.0
**Created:** 2026-03-15 (Sprint 14 V1), **Updated:** 2026-04-04 (V3 — multi-disk, ZIP output, --from-disk)
**Status:** Current

---

## 1. Purpose

The MultiLoad plugin enables classic C64 multi-load games to run from the SD card via EasySD.
These are games whose original floppy releases load additional program parts mid-game using
`LOAD "FILENAME",8,1` or `LOAD "FILENAME",8` Kernal calls.

EasySD cannot emulate a full 1541 drive over the expansion port. Instead, the MultiLoad system
hooks the C64 Kernal LOAD vector (`$0330/$0331`) and intercepts every `JSR $FFD5` call that
targets device 8. Matching calls are served from the SD card at approximately 100× floppy speed.

---

## 2. Quick Start (V3)

```bash
# 1. Build the template (once per firmware update)
python Tools/build.py multiload

# 2. Preview disk contents
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...] --list-only

# 3. Generate game ZIP (first file on first disk = first part, auto-detected)
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...]
# Output: EasySD/build/multiload/GAMENAME.ZIP

# Override first part name if needed:
python Tools/create_multiload.py --from-disk DISK1.d64 --first-part "LOADER"

# 4. Extract the ZIP to SD card root:
#    /MULTILOAD/GAMENAME/
#      EASYLOAD.PRG    ← generated launcher (select this from EasySD menu)
#      LOADER.PRG      ← first game part
#      LEVEL1.PRG      ← subsequent parts (loaded by game via LOAD "LEVEL1",8,1)
#      LEVEL2.PRG
```

No source-code editing or recompiling is needed for individual games.

---

## 3. SD Card Directory Structure

```
/MULTILOAD/
  TURRICAN/
    EASYLOAD.PRG    ← generated launcher
    LOADER.PRG      ← first game part
    LEVEL1.PRG      ← subsequent parts (loaded by game code)
    LEVEL2.PRG
  PARADROID/
    EASYLOAD.PRG    ← generated launcher
    ROBBIE.PRG
    DROID.PRG
```

Navigate to the game directory in the EasySD menu and select `EASYLOAD.PRG`.

**Filename matching:**
- `LOAD "LEVEL1",8,x` → hook searches for `LEVEL1.PRG`
- `LOAD "LEVEL1.PRG",8,x` → hook searches for `LEVEL1.PRG` (extension already present)
- Extension check: last four characters compared to `.PRG` (uppercase, case-sensitive)

---

## 4. Game Compatibility Guide

### 4.1 Compatible: Sequential Multi-Load Games

These games load program parts one after another as the player progresses through the game.
The previous part triggers the next `LOAD` call — there is no random access by the player.

**Key indicators of compatibility:**

| Signal | Details |
|--------|---------|
| Small file count | Typically 3–30 files per disk |
| Sequential naming | `PART1`/`PART2`, `11`/`12`/`21`/`22`, `LA1`/`LB1`/`LC1` |
| Single main PRG | One large loader that chains into level/data files |
| SD2IEC compatible note | NFO says "loads on SD2IEC" → standard Kernal LOAD, ideal |
| Multi-disk with no duplicates | Each disk contributes unique files for later stages |

**Known compatible games (tested with create_multiload.py):**

| Game | Disks | Files | Notes |
|------|-------|-------|-------|
| Barbarian 1&2 (Palace) | 1 | 4 | BOOT→MENU→game choice; simple chain |
| The Last Ninja +12DGI | 2 | 27 | Main + 4 files/level × 6 levels |
| Turrican 2 (notw) | 2 | 22 | "no transwarp" version; world-based loading |
| Robocop Ocean fix2 | 1 | 3 | SD2IEC-fixed release; 85 KB main file |

### 4.2 Not Compatible: Random-Access Loaders

These games load files by name or ID based on player actions (entering a town, selecting a
level, etc.). The same file may be loaded at any point, in any order.
EasySD has no seek-within-file API, so these games cannot run.

**Key indicators of incompatibility:**

| Signal | Details |
|--------|---------|
| Large file count | 50+ files, often 100–350 |
| Hex or alphabetical data names | `A0`, `B3`, `EF`, `FA`–`FY`, `MA`–`MY` |
| Large single data file (>64 KB) | Cannot fit in C64 RAM; must be seeked into |
| Identical files across disks | Many duplicates between disks = redundant region data |
| RPG / open-world structure | Map/town/dungeon data loaded on demand |

**Known incompatible games:**

| Game | Files | Reason |
|------|-------|--------|
| Ultima IV Remastered | 10 | 136 KB GAM file; random seeks |
| Ultima V Remastered | 229 | Dynamic file load by name; BackBit/custom API |
| Knights of Legend | 354 | Hex-named room data; random access |
| Lemmings | 112 | Level select → FA–FY / TA–TY / MA–MY by player choice |
| Sam's Journey | 163 | Hex-named rooms; identical files duplicated across 4 disks |

### 4.3 Special Cases

**Transwarp / fast loader variants:**
Games with a Transwarp or other custom fast loader replace the Kernal LOAD vector with their
own serial routine. The MultiLoad hook intercepts `JSR $FFD5` (Kernal LOAD dispatch), not the
fast loader's own entry point — so the hook cannot intercept those calls.
- **Solution:** use a "notw" (no transwarp) or "standard loader" version of the crack.
  Example: `t2rab-1-notw.d64` instead of `t2rab-1.d64` for Turrican 2.

**EasyFlash packages:**
D64/D81 images containing a `.CRT` file (cartridge image) and an EasyProg flasher PRG.
These require a physical EasyFlash cartridge — incompatible with EasySD.

**BackBit format:**
Games distributed for the BackBit hardware use a BackBit-specific file-access API, not
standard Kernal LOAD. Identified by the `-BackBit` suffix in the disk label or filename.
Not compatible.

### 4.4 Assessment Workflow

```
1. python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2...] --list-only

2. Count files:
     < 30 files  → promising
     30–60 files → borderline, inspect names carefully
     > 60 files  → likely random-access, skip

3. Inspect file naming:
     Sequential numbers (11/12/21, LA1/LB1) → sequential loader ✅
     Hex names (A0/B3/EF) or alpha series (FA–FY) → random-access ❌

4. Check for large single data files:
     Any file > 64 KB → likely seeked into, not fully loaded ❌

5. Check NFO (if available):
     "SD2IEC compatible" → ideal candidate ✅
     "transwarp" / "fast loader" → look for a notw version ⚠️
     "EasyFlash" or ".CRT" → incompatible ❌

6. If compatible: convert and test
     python Tools/create_multiload.py --from-disk DISK1.d64 [...]
     Extract ZIP → SD card /MULTILOAD/GAMENAME/
     Select EASYLOAD.PRG from EasySD menu
```

---

## 5. Components

### 4.1 Config Block (`$C003–$C014`)

The `EASYLOAD.PRG` binary starts with a fixed-layout config block immediately after the
3-byte entry jump. This block is patched by `create_multiload.py` per game.

| Address | Symbol               | Value  | Meaning                              |
|---------|----------------------|--------|--------------------------------------|
| `$C000` | —                    | `JMP MAIN` | Plugin entry point (3 bytes)    |
| `$C003` | `ML_CONFIG_VERSION`  | `2`    | V2 sentinel; checked at runtime      |
| `$C004` | `ML_FIRST_PART_LEN`  | N      | Length of first-part name (1–16)     |
| `$C005–$C014` | `ML_FIRST_PART_NAME` | string | 16 bytes, null-padded        |

**File offset mapping** (for manual inspection or alternative patching tools):

`bootplugin.prg` is a raw binary (`64tass -b`, no load address header). File offset = RAM address − `$C000`.

```
File byte 0     : $C000 — JMP opcode
File byte 1-2   : $C001-$C002 — JMP target (lo/hi)
File byte 3     : $C003 — ML_CONFIG_VERSION
File byte 4     : $C004 — ML_FIRST_PART_LEN
File bytes 5-20 : $C005-$C014 — ML_FIRST_PART_NAME (16 bytes)
```

### 4.2 RL_STUB — Kernal LOAD Trampoline (`$033C`, 52 bytes)

Patched into the Kernal LOAD vector. When the game calls `JSR $FFD5`, the C64 Kernal dispatches
to `$033C` instead of the real Kernal LOAD routine.

```
RL_STUB ($033C):
  PHA
  STX RL_SAVED_X          ; save X (= MEMUSS lo when SA=0)
  STY RL_SAVED_Y          ; save Y (= MEMUSS hi when SA=0)
  LDA $01 → STA RL_SAVED_01   ; save game's memory config
  LDA #$35 → STA $01          ; bank: Kernal ROM → RAM, I/O active
  JSR RL_HANDLER              ; call main handler at $E800
  LDA RL_SAVED_01 → STA $01   ; restore game's memory config
  LDX RL_SAVED_X
  LDY RL_SAVED_Y
  PLA
  RTS                         ; return to Kernal dispatch
```

**Why $01=$35:** `$35` = HIRAM=0, CHAREN=1. Kernal ROM at `$E000–$FFFF` is hidden, making the
handler RAM at `$E800` visible. I/O at `$D000–$DFFF` stays active (required by the mini-CartLib).
ROML (cartridge ROM at `$8000–$9FFF`) remains accessible because LORAM=1 in both `$35` and `$37`.

**RL_NMI_REDIRECT (`$0368`, 3 bytes):** `JMP ($0318)` — installed at RAM `$FFFA/$FFFB` by
`RL_INSTALL`. Under `$01=$35`, NMI vector reads hit RAM at `$FFFA/$FFFB` → this redirect →
`$0318` → TransferHandler. This ensures NMI-driven transfers work correctly inside the hook
without ever switching back to `$01=$37` (which would hide the handler).

### 4.3 RL_HANDLER — Main Hook Handler (`$E800`, ~400 bytes)

The resident handler is physically stored in `EASYLOAD.PRG` and copied to `$E800` RAM by
`RL_INSTALL`. Writes to this region always go to the underlying RAM regardless of the `$01`
banking register (C64/6502: writes always reach RAM).

**Data areas inside the handler image:**

| Address    | Symbol            | Size   | Purpose                              |
|------------|-------------------|--------|--------------------------------------|
| `$E800`    | `RL_HANDLER`      | —      | Entry point                          |
| `$E840`    | `RL_DIR_PATH`     | 64 B   | Game directory path (chdir safety)   |
| `$E880`    | `RL_FNAME_BUF`    | 36 B   | Assembled filename (name + `.PRG`)   |
| `$E8A4`    | `RL_FILEINFO_BUF` | 32 B   | FAT directory entry buffer           |
| `$E8C4`    | `RL_HDR_BUF`      | 256 B  | First-page read buffer               |

**Handler execution flow:**

```
RL_HANDLER (entry):
  LDA KERNAL_DEVICE_NUMBER
  CMP #8                     → if ≠ 8: JMP (RL_ORIG_VEC)  [pass-through to Kernal]

rl_chdir_to_game:
  Save $B7/$BB/$BC
  RL_SetName(RL_DIR_PATH)
  COMMAND_GOTO_PATH           ; navigate Arduino to game directory
  Restore $B7/$BB/$BC

rl_main:
  JSR RL_StartTalking         ; wake Arduino

  Build filename:
    copy KERNAL_FILENAME_LENGTH bytes from (KERNAL_FILENAME_LOW) → RL_FNAME_BUF
    if last 4 bytes ≠ ".PRG": append ".PRG\0"

  Determine load target:
    LDA KERNAL_SECONDARY_ADDRESS
    BNE rl_use_header_addr
    ; SA=0: target = RL_SAVED_X/Y (X/Y saved by RL_STUB = MEMUSS address)
    rl_use_header_addr:
    ; SA=1: target = first 2 bytes of PRG file (header address)

  Open file, get 32-bit size, read first 256 bytes → RL_HDR_BUF:
    bytes 0-1  = PRG load address
    bytes 2-255 = first 254 data bytes

  Copy first 254 data bytes to load target
    if file_size ≤ 255: copy (size-2) bytes only
    if file_size ≥ 256: copy 254 bytes,
      then RL_LoadFileBySize (target=load_addr+254, SKIP=$100)

  Compute end address: X=end_lo, Y=end_hi

  RL_CloseFile
  RL_EndTalking               ; NO banking switch; $01 restored by RL_STUB
  CLC                         ; Kernal convention: C=0 success
  RTS                         ; → RL_STUB restores $01/$X/$Y, returns to game
```

**Kernal return convention:** carry=0, X=end_lo, Y=end_hi. BASIC and other callers update
their own page-end pointers (`$2D/$2E`) from X/Y.

### 4.4 RL_MINI_CARTLIB (embedded, follows RL_HANDLER code)

A self-contained copy of all CartLib routines needed by the handler, embedded inside the
handler image itself. **No `#SETBANK` calls anywhere** — the banking state (`$01=$35`) is
maintained throughout the entire handler execution.

Routines included: `RL_WasteCertainTime`, `RL_WasteTooMuchTime`, `RL_ReceiveFragmentNoCallback`,
`RL_EndTalking`, `RL_WaitProcessing`, `RL_StartTalking`, `RL_Send`, `RL_SendBit`, `RL_SetName`,
`RL_SendFileName`, `RL_OpenFile`, `RL_CloseFile`, `RL_GetInfoForFile`, `RL_ReadFileNoCallback`,
`RL_SeekFile`, `RL_LoadFileBySize`.

**Why embedded:** Many multi-load games load parts to `$C000+`, which would overwrite the
CartLib routines in the main plugin code. The mini-CartLib lives at `$E800+` (Kernal ROM area)
where games never load data, making it immune to overwrite.

### 4.5 RL_INSTALL — One-Time Installer

Called once by `EASYLOAD.PRG` before jumping to the game.

```
RL_INSTALL:
  1. Copy RL_STUB_IMAGE  → $033C     (52 bytes)
  2. Copy RL_HANDLER+RL_MINI_CARTLIB → $E800  (RL_HANDLER_IMAGE_SIZE bytes, multi-page)
  3. Write RL_NMI_REDIRECT ($0368) address → RAM $FFFA/$FFFB
  4. Backup $0330/$0331 → RL_ORIG_VEC ($036B)
  5. Patch $0330 = <RL_STUB ($033C), $0331 = >RL_STUB
  Registers preserved (A/X/Y pushed/popped).
```

---

## 6. Memory Layout (V2)

### 5.1 ResidentLoader Area (during game execution)

| Address        | Symbol            | Content                                         |
|----------------|-------------------|-------------------------------------------------|
| `$0330/$0331`  | —                 | Kernal LOAD vector → patched to `$033C`         |
| `$033C–$0367`  | `RL_STUB`         | 52-byte trampoline (saves A/X/Y/$01, banks $35, calls $E800) |
| `$0368–$036A`  | `RL_NMI_REDIRECT` | `JMP ($0318)` — also written to `$FFFA/$FFFB`   |
| `$036B–$036C`  | `RL_ORIG_VEC`     | Backup of original `$0330/$0331`                |
| `$036D`        | `RL_SAVED_01`     | Saved `$01` during LOAD hook                    |
| `$036E`        | `RL_SAVED_X`      | Saved X at LOAD call time (SA=0 MEMUSS lo)      |
| `$036F`        | `RL_SAVED_Y`      | Saved Y at LOAD call time (SA=0 MEMUSS hi)      |
| `$FFFA/$FFFB`  | —                 | RAM NMI vector → `RL_NMI_REDIRECT` (written by RL_INSTALL) |
| `$E800–$E8C3`  | `RL_HANDLER`      | Handler code + data area headers                |
| `$E840`        | `RL_DIR_PATH`     | 64-byte game directory path                     |
| `$E880`        | `RL_FNAME_BUF`    | 36-byte filename buffer                         |
| `$E8A4`        | `RL_FILEINFO_BUF` | 32-byte FAT entry buffer                        |
| `$E8C4`        | `RL_HDR_BUF`      | 256-byte first-page read buffer                 |
| `$E8C4–$EBxx`  | `RL_MINI_CARTLIB` | Embedded CartLib (no `#SETBANK`, ~700 bytes)    |

**Note:** `$033C–$036F` overlaps with `FILE_PATH_BUF` used by the menu/plugins. The two uses
are mutually exclusive (game execution vs. menu navigation) and therefore safe.

### 5.2 EASYLOAD.PRG Plugin Code (`$C000+`)

| Address Range     | Content                                                  |
|-------------------|----------------------------------------------------------|
| `$C000`           | `JMP MAIN`                                               |
| `$C003–$C014`     | Config block (version, len, name — patched per game)     |
| `$C015+`          | MAIN, ML_SAVESTATE/RESTORESTATE                          |
| `$C0xx`           | ML_FILEINFO_BUF (32 B), ML_HDRBUF (256 B)                |
| `$C1xx–$Cxxx`     | RL_STUB image, RL_HANDLER+mini-CartLib image, RL_INSTALL |
| `$Cxxx–$Dxxx`     | CartLibStream chain (for MAIN's IRQ_StartTalking/GetPath) |

Overflow guard: `.if * > $DF00 .error "overflow" .endif`

---

## 7. EASYLOAD.PRG Boot Flow

```
User navigates to /MULTILOAD/TURRICAN/ in EasySD menu
  └─ Selects EASYLOAD.PRG
       ↓
Menu loads EASYLOAD.PRG to $C000, JMPs to $C000

EASYLOAD.PRG (MAIN at $C015):
  1. JSR ML_SAVESTATE             save VIC/$01 for error-path cleanup
  2. JSR RL_INSTALL               copy stub+handler, patch $0330, write $FFFA/$FFFB
  3. JSR IRQ_StartTalking         wake Arduino (already in game directory)
  4. COMMAND_GET_PATH             Arduino sends 64-byte path → stored at $E840 (RL_DIR_PATH)
  5. IRQ_SetName (ML_FIRST_PART_NAME from config block)
     IRQ_OpenFile
  6. IRQ_GetInfoForFile            32-bit file size
  7. IRQ_ReadFileNoCallback        first 256 bytes → ML_HDRBUF
  8. Copy first 254 data bytes to PRG load address
     LoadFileBySize (remainder) if file_size ≥ 256
  9. IRQ_CloseFile / IRQ_EndTalking
  10. JMP (load_address)           ← game starts; resident hook active; never returns

If any step fails:
  IRQ_EndTalking → ML_RESTORESTATE → IRQ_ExitToMenu
```

**After step 10:** The resident hook at `$033C` intercepts all `JSR $FFD5` calls targeting
device 8. Before each file access, the hook navigates the Arduino back to the game directory
via `COMMAND_GOTO_PATH` — ensuring correct operation even if the Arduino's working directory
has drifted.

---

## 8. NMI Transfer Under $01=$35

The NMI-driven transfer protocol requires the CPU to read the NMI vector at `$FFFA/$FFFB`.

- **With `$01=$37`** (normal): `$FFFA/$FFFB` reads from Kernal ROM (`$FE43`) → JMP `$0318`
- **With `$01=$35`** (handler): `$FFFA/$FFFB` reads from RAM → must contain a valid vector

`RL_INSTALL` writes `$68,$03` (= address `$0368`) to RAM `$FFFA/$FFFB`. This address contains
`RL_NMI_REDIRECT` = `JMP ($0318)`. On NMI under `$01=$35`:

```
CPU reads $FFFA/$FFFB → $0368 → JMP ($0318) → TransferHandler ($80AF)
```

This eliminates any need to switch back to `$01=$37` during transfers.

ROML (cartridge ROM at `$8000–$9FFF`) is accessible in both `$01=$35` and `$01=$37` because
LORAM=1 in both cases. TransferHandler at `$80AF` is therefore always reachable.

---

## 9. SA=0 (MEMUSS) Support

When a game uses `SETLFS #1,#8,#0` + `JSR $FFD5` (secondary address 0), the Kernal ignores
the PRG header address and loads to the address held in X/Y registers (`MEMUSS` low/high).

**V2 handling:**
1. `RL_STUB` saves X and Y to `RL_SAVED_X` / `RL_SAVED_Y` before modifying registers
2. `RL_HANDLER` checks `KERNAL_SECONDARY_ADDRESS` (`$B9`):
   - SA=0 → load target = `RL_SAVED_X` / `RL_SAVED_Y`
   - SA≠0 → load target = first 2 bytes of PRG file (standard PRG header address)
3. In both cases the PRG file has a 2-byte header on disk (`SKIP=$100` is always used)

---

## 10. create_multiload.py (V3)

### Modes

```bash
# --- D64/D81 disk image mode (V3) ---

# Preview: list all files from one or more disk images
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...] --list-only

# Generate ZIP (first file on first disk = first part)
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...]

# Override which file is the first part
python Tools/create_multiload.py --from-disk DISK1.d64 [DISK2.d64 ...] --first-part "LOADER"

# --- Autoswap list mode (V3) ---
python Tools/create_multiload.py --from-autoswap autoswap.lst [--first-part NAME]

# --- Legacy positional mode (V2, still works) ---
python Tools/create_multiload.py FIRST_PART_NAME
```

### Output

- **ZIP:** `EasySD/build/multiload/GAMENAME.ZIP`
  - `GAMENAME` = parent folder name of the first disk image (uppercased)
  - ZIP contents mirror the SD card layout:
    ```
    MULTILOAD/GAMENAME/EASYLOAD.PRG
    MULTILOAD/GAMENAME/FIRSTPART.PRG
    MULTILOAD/GAMENAME/FILE2.PRG
    ...
    ```
- **Multi-disk deduplication:** if the same filename appears on multiple disks, the first occurrence (lowest disk number) is used.
- **Legacy mode output:** `EasySD/build/multiload/EASYLOAD.PRG` (single file, no ZIP)

### What it patches in bootplugin.prg

Reads `EasySD/build/plugins/bootplugin.prg` (raw binary, `$C000` base), patches the config
block, packages as ZIP.

| File offset | Field              | Value                         |
|-------------|-------------------|-------------------------------|
| 3           | ML_CONFIG_VERSION  | unchanged (must be 2)         |
| 4           | ML_FIRST_PART_LEN  | `len(FIRST_PART_NAME)`        |
| 5–20        | ML_FIRST_PART_NAME | name bytes + zero padding     |

**Verification checks:**
- ML_CONFIG_VERSION must be `2`
- Name length must be 1–16 characters

---

## 11. Build System Integration

| Command | Output | Notes |
|---------|--------|-------|
| `python Tools/build.py multiload` | `EasySD/build/plugins/bootplugin.prg` | Build template only |
| `python Tools/create_multiload.py NAME` | `EasySD/build/multiload/EASYLOAD.PRG` | Patch for specific game |
| `python Tools/build.py plugins` | all `.prg` in `EasySD/build/plugins/` | All plugins |
| `python Tools/build.py release` | all artifacts | Full build |

`bootplugin` is defined in `PLUGIN_MATRIX` in `Tools/build.py`.

---

## 12. Known Limitations

| Limitation | Detail |
|------------|--------|
| Game loads to `$033C–$036F` | Overwrites RL_STUB → hook stops working. Very rare. |
| Game loads to `$E800–$EBxx` | Overwrites handler + mini-CartLib. Extremely rare (Kernal ROM area). |
| Direct `JSR $E16F` (bypass `$0330`) | Cannot be intercepted without a dedicated expansion port cartridge. Not used by typical games. |
| `LOAD` with device ≠ 8 | Passed through to original Kernal LOAD vector; works normally. |
| ZIP folder naming collision | `create_multiload.py` derives the game folder name from the **parent folder** of the first D64 file (priority 1), then disk label (priority 2), then filename stem (priority 3). If multiple D64 files are stored in a generic folder (e.g. `NEW/`), the resulting ZIPs all use `MULTILOAD/NEW/` — extracting them overwrites each other. **Workaround:** store each game's disk images in a correctly-named subfolder (e.g. `BARBARIAN/game.d64`), or rename the MULTILOAD subfolder manually after extraction. A `--game-name` override option does not yet exist. |

---

## 13. Key Source Files

| File | Purpose |
|------|---------|
| `EasySD/Loader/ResidentLoader.s` | RL_STUB + RL_NMI_REDIRECT + RL_HANDLER + RL_MINI_CARTLIB images; RL_INSTALL |
| `EasySD/Loader/Bridges/MultiLoad/MultiLoad.s` | EASYLOAD.PRG plugin (config block, MAIN, first-part loader) |
| `EasySD/Loader/Common/System.inc` | All `RL_*` address constants |
| `EasySD/Loader/CartZpMap.inc` | `$033C–$036F` dual-use annotation; `$8B–$8E` handler scratch |
| `Tools/create_multiload.py` | Per-game config block patcher |
| `Arduino/EasySD/CartApi.cpp` | `COMMAND_GOTO_PATH` handler |
| `Arduino/EasySD/DirFunction.cpp` | `NavigateToPath()` — parses absolute path, chdirs segment by segment |
