# EasySD MultiLoad Plugin — Multi-Load Game Launcher

**Document Type:** Reference / User Guide
**Version:** 2.0
**Created:** 2026-03-15 (Sprint 14 V1), **Updated:** 2026-03-16 (Sprint 15 V2)
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

## 2. Quick Start (V2)

```bash
# 1. Build the template (once per firmware update)
python Tools/build.py multiload

# 2. Generate game-specific launcher
python Tools/create_multiload.py LOADER      # first part is LOADER.PRG
# Output: EasySD/build/multiload/EASYLOAD.PRG

# 3. Copy to SD card
#    /MULTILOAD/TURRICAN/
#      EASYLOAD.PRG    ← generated launcher (select this from EasySD menu)
#      LOADER.PRG      ← first game part (ML_FIRST_PART_NAME = "LOADER")
#      LEVEL1.PRG      ← LOAD "LEVEL1",8,1 from game code
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

## 4. Components

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

```
File byte 0-1   : load address $0801 (BASIC SYS wrapper from easysd.obj, 15 bytes)
File byte 15    : $C000 — JMP opcode
File byte 18    : $C003 — ML_CONFIG_VERSION
File byte 19    : $C004 — ML_FIRST_PART_LEN
File bytes 20-35: $C005 — ML_FIRST_PART_NAME (16 bytes)
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

## 5. Memory Layout (V2)

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

## 6. EASYLOAD.PRG Boot Flow

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

## 7. NMI Transfer Under $01=$35

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

## 8. SA=0 (MEMUSS) Support

When a game uses `SETLFS #1,#8,#0` + `JSR $FFD5` (secondary address 0), the Kernal ignores
the PRG header address and loads to the address held in X/Y registers (`MEMUSS` low/high).

**V2 handling:**
1. `RL_STUB` saves X and Y to `RL_SAVED_X` / `RL_SAVED_Y` before modifying registers
2. `RL_HANDLER` checks `KERNAL_SECONDARY_ADDRESS` (`$B9`):
   - SA=0 → load target = `RL_SAVED_X` / `RL_SAVED_Y`
   - SA≠0 → load target = first 2 bytes of PRG file (standard PRG header address)
3. In both cases the PRG file has a 2-byte header on disk (`SKIP=$100` is always used)

---

## 9. create_multiload.py

```bash
python Tools/create_multiload.py FIRST_PART_NAME
```

Reads the template `EasySD/build/plugins/bootplugin.prg`, patches the config block,
writes `EasySD/build/multiload/EASYLOAD.PRG`.

**What it patches:**

| File offset | Field              | Value                         |
|-------------|--------------------|-------------------------------|
| 18          | ML_CONFIG_VERSION  | unchanged (must be 2)         |
| 19          | ML_FIRST_PART_LEN  | `len(FIRST_PART_NAME)`        |
| 20–35       | ML_FIRST_PART_NAME | name bytes + zero padding     |

**Verification checks:**
- PRG load address must be `$0801`
- ML_CONFIG_VERSION must be `2`
- Name length must be 1–16 characters

---

## 10. Build System Integration

| Command | Output | Notes |
|---------|--------|-------|
| `python Tools/build.py multiload` | `EasySD/build/plugins/bootplugin.prg` | Build template only |
| `python Tools/create_multiload.py NAME` | `EasySD/build/multiload/EASYLOAD.PRG` | Patch for specific game |
| `python Tools/build.py plugins` | all `.prg` in `EasySD/build/plugins/` | All plugins |
| `python Tools/build.py release` | all artifacts | Full build |

`bootplugin` is defined in `PLUGIN_MATRIX` in `Tools/build.py`.

---

## 11. Known Limitations

| Limitation | Detail |
|------------|--------|
| Game loads to `$033C–$036F` | Overwrites RL_STUB → hook stops working. Very rare. |
| Game loads to `$E800–$EBxx` | Overwrites handler + mini-CartLib. Extremely rare (Kernal ROM area). |
| Direct `JSR $E16F` (bypass `$0330`) | Cannot be intercepted without a dedicated expansion port cartridge. Not used by typical games. |
| `LOAD` with device ≠ 8 | Passed through to original Kernal LOAD vector; works normally. |

---

## 12. Key Source Files

| File | Purpose |
|------|---------|
| `EasySD/Loader/ResidentLoader.s` | RL_STUB + RL_NMI_REDIRECT + RL_HANDLER + RL_MINI_CARTLIB images; RL_INSTALL |
| `EasySD/Loader/Bridges/MultiLoad/MultiLoad.s` | EASYLOAD.PRG plugin (config block, MAIN, first-part loader) |
| `EasySD/Loader/Common/System.inc` | All `RL_*` address constants |
| `EasySD/Loader/CartZpMap.inc` | `$033C–$036F` dual-use annotation; `$8B–$8E` handler scratch |
| `Tools/create_multiload.py` | Per-game config block patcher |
| `Arduino/EasySD/CartApi.cpp` | `COMMAND_GOTO_PATH` handler |
| `Arduino/EasySD/DirFunction.cpp` | `NavigateToPath()` — parses absolute path, chdirs segment by segment |
