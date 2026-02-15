# EasySD Architecture Refactoring Plan

## Executive Summary

This plan refactors the EasySD system to fix unstable directory navigation and clarify PRG vs RAW file loading. The core principle: **Arduino firmware is the single source of truth for filesystem state**. The C64 menu becomes a thin UI layer that only sends basenames, never builds paths.

## Current Architecture Analysis

### C64 Side (IrqLoaderMenuNew.s)
- **Zero Page Usage**: $FB-$FE for menu pointers (NAMELOW, NAMEHIGH, COLLOW, COLHIGH)
- **RAM Variables**:
  - PATHBUFFER at $033C (cassette buffer, 160 bytes)
  - FILENAMESHADOW at $0200
  - DIRSTACKTEMP at $FD00
  - DIRSTACK (320 bytes for directory history)
- **Directory Management**:
  - CURRENTDIRINDEX tracks depth
  - PUSHDIRNAME/POPDIRNAME manage local stack
  - BuildAbsolutePathFromPtr constructs full paths from DIRSTACK
  - GOBACK attempts to navigate parent by reconstructing path

### Arduino Side (DirFunction.cpp, CartApi)
- Uses **SdFat library** (full FAT filesystem)
- DirFunction tracks `currentPath` string and `pathDepth`
- Methods: `ToRoot()`, `GoBack()`, `ChangeDirectory()`
- Command protocol: COMMAND_READ_DIR (10), COMMAND_CHANGE_DIR (11)

### The Problem
**State synchronization issues between C64 and Arduino:**
1. C64 maintains its own directory stack (DIRSTACK, CURRENTDIRINDEX)
2. Arduino maintains its own path (currentPath, pathDepth)
3. Any timeout, error, or edge case can desynchronize them
4. Results: color flashes, navigation failures, freezes

## Solution Architecture

### Core Principle: Firmware-Centric State Management

**Arduino firmware owns:**
- Canonical current working directory (CWD) as absolute path string
- All directory traversal logic
- File open/read/close operations

**C64 menu responsibilities:**
- Display UI only
- Send basename commands ("GAMES", "..", "INTRO.SID")
- Never build absolute paths
- Never track directory state

## Implementation Plan

### Phase 1: Arduino Firmware Refactoring

#### 1.1 Consider PetitFatFs Migration (Optional, Future)
The terv.txt suggests PetitFatFs for minimal footprint. Current implementation uses SdFat which works well. **Decision point:**
- **Keep SdFat initially** (working, stable, easier to debug)
- **Document PetitFatFs migration path** for future optimization
- PetitFatFs constraints: one file at a time, sequential directory reads
  - Reference: [PetitFatFs documentation](https://elm-chan.org/fsw/ff/00index_p.html)
  - Memory: 44 bytes RAM, 2K-4K code
  - Arduino library: [greiman/PetitFS](https://github.com/greiman/PetitFS)

#### 1.2 Enhanced Directory Management (DirFunction.cpp/h)

**Add new methods:**

```cpp
// Enhanced directory navigation
bool ChangeDirectoryBasename(const char* basename) {
    if (strcmp(basename, "..") == 0) {
        return GoBackParent();
    }
    // Navigate to subdirectory
    return EnterSubdirectory(basename);
}

// Canonical path handling
const char* GetCurrentPath() {
    return currentPath;
}

// Reset to known good state
void ForceReset() {
    ToRoot();
    // Clear any cached state
}
```

**Key changes:**
- `ChangeDirectoryBasename()` accepts only basenames, never absolute paths
- Firmware validates that basename exists before changing
- Return error codes on failure (maintain C64-side state consistency)
- Log all directory operations for debugging

#### 1.3 Directory Session API (CartApi.cpp)

**Implement clean session model:**

```cpp
// DIR SESSION API (for menu)
void HandleReadDirectory() {
    // Current: uses DirFunction::Prepare() + Iterate()
    // Keep existing logic, but ensure:
    // 1. Always returns current directory contents
    // 2. Includes ".." as first entry if not at root
    // 3. Sequential iteration (no random access needed)
}

void HandleChangeDirectory() {
    // Parse Arguments[0..n] as basename
    // Call dirFunc.ChangeDirectoryBasename(basename)
    // Return success/error to C64
    // CRITICAL: Only change CWD if operation succeeds
}
```

#### 1.4 File API Clarification (CartApi.cpp)

**Three distinct operation modes:**

```cpp
// 1. RAW FILE API (for plugin data)
//    Never skips anything, byte-exact
void HandleOpenFile() {
    // Flags: READ or WRITE
    // Opens file in CWD
    // workingFile = relative to currentPath
}

void HandleReadFile() {
    // Read bytes exactly as stored
    // No PRG header processing
}

// 2. PRG LOAD API (implicit in menu)
//    Currently: menu reads first 2 bytes as load address
//    Keep this pattern, but document it clearly
//    Plugins that need PRG loading handle it themselves

// 3. STREAM API (for media playback)
//    Already implemented (COMMAND_STREAM, COMMAND_NI_STREAM)
//    Keep existing streaming logic
```

**Critical rule: RAW API never skips bytes, PRG logic is explicit in caller**

### Phase 2: C64 Menu Code Refactoring (IrqLoaderMenuNew.s)

#### 2.1 Remove C64-Side Directory Stack

**Files to modify:**
- `C:\EasySD Gemini\IRQHack64\Menus\EasySD\IrqLoaderMenuNew.s`

**Remove/deprecate:**
```assembly
; Old variables to remove:
; DIRSTACK (320 bytes)
; CURRENTDIRINDEX
; DIRNAMESLO/DIRNAMESHI arrays
; PUSHDIRNAME routine
; POPDIRNAME routine
; BuildAbsolutePathFromPtr routine
; GOBACK routine
```

**Memory reclaimed: ~400+ bytes** (DIRSTACK + code)

#### 2.2 New Directory Navigation Logic

**Simplified ENTER key handler:**

```assembly
ENTER:
    JSR IRQ_DisableDisplay

    ; Check if special command (next/prev page)
    LDA COMMANDBYTE
    AND #$40
    BNE SPECIALCMD

    ; Get selected item
    JSR GETCURRENTROW          ; X = current row
    JSR ISDIRECTORY
    BNE NODIRECTORY            ; Not a directory -> file selection

    ; It's a directory - send basename to firmware
    ; Selected name is already in NAMESLO/NAMESHI[X]
    LDA NAMESLO, X
    STA $06
    LDA NAMESHI, X
    STA $07

    ; Send basename via IRQ_SetNameZ (0-terminated)
    TXA
    PHA
    LDX $06
    LDY $07
    JSR IRQ_SetNameZ           ; Sets name for next command
    PLA
    TAX

    ; Call firmware to change directory
    JSR IRQ_ChangeDirectory
    BCS CHANGEDIRFAIL          ; Carry set = error

    ; Success - read new directory contents
    JMP DOREADDIRECTORY
```

**Key differences:**
- No PUSHDIRNAME/POPDIRNAME calls
- No path building
- Firmware handles ".." automatically
- Simpler error handling

#### 2.3 File Selection and Plugin Invocation

**Current flow (keep similar structure):**
```assembly
NODIRECTORY:
    ; Not a directory, it's a file
    JSR GETCURRENTROW          ; X = selected row

    ; Get filename pointer
    LDA NAMESLO, X
    TAY
    LDA NAMESHI, X
    TAX
    TYA

    ; Determine file type
    JSR CHECKFILENAME
    JSR ISPRG
    BCC PROGRAM
    CMP #TYPE_PROGRAM
    BEQ PROGRAM
    CMP #TYPE_CHECK_PLUGIN
    BEQ PLUGIN
```

**For plugins - pass basename only:**
```assembly
PLUGIN:
    ; Build plugin filename (e.g., "MUSPLUGIN.PRG")
    JSR BUILDPLUGINNAME_BIN    ; or _PRG

    ; Set plugin name
    LDX #<PLUGINNAME
    LDY #>PLUGINNAME
    JSR IRQ_SetNameZ

    ; Open plugin (PRG format)
    LDX #01                    ; Flags = READ
    JSR IRQ_OpenFile
    BCC PLUGIN_EXISTS

    ; Fall through to error handling
```

**Plugin receives selected filename as parameter:**
- Pass basename in known location (e.g., FILENAMESHADOW at $0200)
- Plugin uses IRQ_SetNameZ + IRQ_OpenFile to open data file
- Plugin decides: RAW read or PRG load based on file type

#### 2.4 Zero Page and Memory Management

**Optimized zero page usage (TASS64 best practices):**

Current usage (keep):
```assembly
; User range $FB-$FE (safe for ML programs)
NAMELOW  = $FB    ; Pointer to name (lo)
NAMEHIGH = $FC    ; Pointer to name (hi)
COLLOW   = $FD    ; Pointer to color (lo)
COLHIGH  = $FE    ; Pointer to color (hi)
```

**Additional zero page for temporary work ($02-$8F range):**
```assembly
; Temporary pointers during operations
TEMP_PTR = $06    ; 2 bytes ($06-$07) - used in navigation
TEMP_IDX = $08    ; 1 byte - temporary index storage
```

**Memory map summary:**
- **$0200-$02FF**: FILENAMESHADOW (selected file parameter to plugins)
- **$033C-$03FF**: PATHBUFFER (cassette buffer, 160 bytes) - still used for filename operations
- **$C000-$CFFF**: Plugin load area (4K window)
- **$FD00-$FDFF**: DIRSTACKTEMP (can be repurposed or removed)

### Phase 3: CartLib API Enhancement (CartLib.s, CartLibHi.s)

#### 3.1 Document Existing APIs

**Files:**
- `C:\EasySD Gemini\IRQHack64\Loader\CartLib.s` (low-level communication)
- `C:\EasySD Gemini\IRQHack64\Loader\CartLibHi.s` (high-level API)

**Directory operations (keep as-is, update docs):**
```assembly
IRQ_ReadDirectoryNC:
    ; Reads directory contents from firmware
    ; Input: X = max items, Y = offset, A = page index
    ; Output: DIRLOAD buffer filled
    ; Carry: 0 = success, 1 = error

IRQ_ChangeDirectory:
    ; Changes directory on firmware
    ; Prerequisites: IRQ_SetName or IRQ_SetNameZ called first
    ; Input: Name set via IRQ_SetName(Z)
    ; Output: Carry: 0 = success, 1 = failure
    ; Note: Firmware handles ".." and validates path
```

**File operations (clarify RAW vs PRG):**
```assembly
IRQ_OpenFile:
    ; Opens file for RAW byte-level access
    ; Prerequisites: IRQ_SetName(Z) called
    ; Input: X = flags ($01 = read, $02 = write)
    ; Output: Carry: 0 = success, 1 = error
    ; IMPORTANT: This is RAW mode - no PRG processing

IRQ_ReadFileNoCallback:
    ; Reads RAW bytes from open file
    ; Input: ZP_IRQ_DATA_LOW/HIGH = dest, ZP_IRQ_DATA_LENGTH = pages
    ; Output: Carry: 0 = success, 1 = error
    ; IMPORTANT: Reads exact bytes, no skipping

IRQ_GetInfoForFile:
    ; Gets file size and metadata
    ; Used to determine file size before loading
```

**Add new helper (optional):**
```assembly
IRQ_LoadPRGFile:
    ; Convenience routine for PRG loading
    ; 1. Opens file
    ; 2. Reads first 2 bytes as load address
    ; 3. Loads remainder to that address
    ; This encapsulates the PRG pattern used everywhere
```

### Phase 4: Plugin Updates

#### 4.1 Update Plugin Interface Contract

**All plugins (MUS, WAV, KOA, PETG, CVID, PRG):**

**Entry point receives:**
- Selected filename at FILENAMESHADOW ($0200), 0-terminated
- File is in current directory on firmware
- Plugin must call IRQ_SetNameZ + IRQ_OpenFile itself

**Plugin responsibilities:**
1. Parse filename from FILENAMESHADOW
2. Call `IRQ_SetNameZ` with filename pointer
3. Call `IRQ_OpenFile` with appropriate flags
4. For **data files** (MUS, WAV, KOA, etc.): Use RAW reading
5. For **PRG files** (player code): Read load address, then payload
6. Always call `IRQ_CloseFile` when done
7. Return to menu via `IRQ_ExitToMenu`

#### 4.2 Example: MusPlayer.s Updates

**Current code at LoadSelectedMus8000 (keep structure):**
```assembly
LoadSelectedMus8000:
    ; Selected MUS filename is in FILENAMESHADOW
    ldx #<FILENAMESHADOW
    ldy #>FILENAMESHADOW
    jsr IRQ_SetNameZ           ; Set name from parameter

    ldx #$01                   ; READ flag
    jsr IRQ_OpenFile
    bcs LoadMus_Fail

    ; Read file as RAW bytes (MUS files are RAW data)
    lda #<SONG_ADDRESS
    sta ZP_IRQ_DATA_LOW
    lda #>SONG_ADDRESS
    sta ZP_IRQ_DATA_HIGH
    lda #$10                   ; 16 pages = 4KB max
    sta ZP_IRQ_DATA_LENGTH

    jsr IRQ_ReadFileNoCallback ; RAW read, no skip
    bcs LoadMus_FailClose

    jsr IRQ_CloseFile
    clc
    rts
```

**Plugins to update:**
- `C:\EasySD Gemini\IRQHack64\Plugins\MusPlayer\MusPlayer.s`
- `C:\EasySD Gemini\IRQHack64\Plugins\WavPlayer\WavPlayer.s`
- `C:\EasySD Gemini\IRQHack64\Plugins\KoalaDisplayer\KoalaDisplayer.s`
- `C:\EasySD Gemini\IRQHack64\Plugins\PetsciiDisplayer\PetsciiDisplayer.s`
- `C:\EasySD Gemini\IRQHack64\Plugins\PrgPlugin\PrgPlugin.s`

### Phase 5: Testing and Validation

#### 5.1 Directory Navigation Tests
1. Enter subdirectory → verify contents
2. Enter nested subdirs (depth 3-4) → verify contents at each level
3. Use ".." to go back → verify previous contents
4. Mix enter/back operations → verify state consistency
5. Page through long directories → verify page navigation
6. Test at root → verify ".." doesn't appear, can't go back

#### 5.2 File Loading Tests
1. PRG file → verify loads to correct address, runs correctly
2. MUS file → verify plugin loads RAW bytes, plays correctly
3. WAV file → verify streaming works
4. KOA/PETG → verify image displays correctly
5. Large files → verify complete loading
6. Sequential operations → verify no file handle leaks

#### 5.3 Error Handling Tests
1. Non-existent directory → verify error returned, state unchanged
2. Non-existent file → verify error returned, state unchanged
3. SD card removal → verify graceful failure
4. Timeout conditions → verify recovery
5. Plugin errors → verify clean return to menu

## Implementation Order

### Sprint 1: Firmware Foundation (Week 1)
1. Update DirFunction.cpp with basename navigation
2. Update CartApi.cpp HandleChangeDirectory
3. Add comprehensive error codes and logging
4. Test firmware in isolation via serial commands

### Sprint 2: C64 Menu Refactor (Week 2)
1. Create backup of IrqLoaderMenuNew.s
2. Remove DIRSTACK, PUSHDIRNAME, POPDIRNAME, GOBACK
3. Implement simplified ENTER handler
4. Update file selection logic
5. Test menu navigation with firmware

### Sprint 3: Plugin Updates (Week 3)
1. Update plugin parameter passing
2. Refactor MUS plugin as reference
3. Update remaining plugins
4. Test each plugin individually
5. Integration testing

### Sprint 4: Testing and Polish (Week 4)
1. Comprehensive testing (see Phase 5)
2. Performance optimization
3. Documentation updates
4. Code cleanup and comments

## C64-Specific Technical Considerations

### Zero Page Management (TASS64)
```assembly
; Safe zero page ranges for machine language:
; $FB-$FE: Generally safe (used by this menu)
; $02, $06-$0A: Safe if not using BASIC
; Avoid: $00-$01 (processor port), $90-$FF (KERNAL)
```

### Memory Management Best Practices
- **Cassette buffer ($033C-$03FF)**: 196 bytes, safe for ML
- **Screen memory ($0400-$07FF)**: In use by menu
- **Color RAM ($D800-$DBE7)**: In use by menu
- **Plugin space ($C000-$CFFF)**: 4K cartridge window
- **KERNAL ROM ($E000-$FFFF)**: Use via JSR to kernal routines
- **I/O area ($D000-$DFFF)**: VIC, SID, CIA access

### TASS64 Assembly Techniques
```assembly
; Use macros for common operations
DELAYFRAMES .macro
    LDX #\1
    JSR WAITFRAMES
.endm

; ROM access control
CART_ROM_ENABLE .macro
    LDA #$37        ; BASIC+KERNAL+I/O+Cart
    STA $01
.endm

; Relocatable code with .logical directive
.logical $C000
    ; Plugin code here
.endlogical
```

## Risk Mitigation

### Risk: State desync during errors
**Mitigation:**
- Firmware validates all operations before changing state
- C64 always requests fresh directory read after any error
- Add "Reset Navigation" debug command (return to root)

### Risk: Breaking existing functionality
**Mitigation:**
- Comprehensive backup before changes
- Keep old code in `.old` files during development
- Incremental testing at each stage
- Maintain debug mode with mock data

### Risk: Plugin compatibility
**Mitigation:**
- Update plugin interface in phases
- Test reference plugin (MUS) thoroughly first
- Document new parameter passing clearly
- Maintain backward compatibility option during transition

## Success Criteria

1. **Stability**: No more directory navigation freezes or color flashes
2. **Correctness**: Directory state always matches firmware reality
3. **Simplicity**: C64 code is smaller and easier to understand
4. **Clarity**: PRG vs RAW loading is explicit and documented
5. **Performance**: No degradation in speed or responsiveness
6. **Compatibility**: All plugins work with new interface

## Future Enhancements (Post-Implementation)

1. **PetitFatFs migration**: Reduce Arduino RAM usage
2. **Long filename support**: Extend beyond 8.3 format
3. **Favorites/bookmarks**: Quick access to common files
4. **Search function**: Find files across directories
5. **File operations**: Copy, move, delete from menu
6. **Network support**: HTTP/FTP file access (per SOURCE_TYPE_ constants)

## Documentation Updates Needed

1. Update CartLib API reference with PRG vs RAW clarification
2. Update plugin development guide with new parameter interface
3. Add directory navigation architecture diagram
4. Document zero page and memory usage map
5. Add troubleshooting guide for common issues

## References

**External Resources:**
- [64tass (TASS64) Reference Manual](https://tass64.sourceforge.net/)
- [PetitFatFs Module](https://elm-chan.org/fsw/ff/00index_p.html)
- [Arduino PetitFS Library](https://github.com/greiman/PetitFS)
- [SdFat Arduino Library Documentation](https://www.if.ufrj.br/~pef/producao_academica/artigos/audiotermometro/audiotermometro-I/bibliotecas/SdFat/Doc/html/)
- [C64 Memory Map Reference](https://www.c64-wiki.com/wiki/Memory_Map)

**Project Files:**
- Source: `terv.txt` (original requirements document)
- C64 Menu: `C:\EasySD Gemini\IRQHack64\Menus\EasySD\IrqLoaderMenuNew.s`
- Arduino Firmware: `C:\EasySD Gemini\Arduino\IRQHack64\IRQHack64.ino`
- Directory Management: `C:\EasySD Gemini\Arduino\IRQHack64\DirFunction.cpp`
- Command API: `C:\EasySD Gemini\Arduino\IRQHack64\CartApi.cpp`
- CartLib: `C:\EasySD Gemini\IRQHack64\Loader\CartLib.s` and `CartLibHi.s`
- Plugins: `C:\EasySD Gemini\IRQHack64\Plugins\*\*.s`

---

**End of Plan**

This plan provides a complete roadmap for refactoring the EasySD architecture to achieve stable directory navigation and clear file loading semantics, while respecting C64 hardware constraints and TASS64 assembly best practices.
