# Refactor Plan: Eliminate EASYLOAD.PRG and MultiLoad.s MAIN

> Status: PLAN — not yet implemented. Drafted 2026-05-02 after real-HW serial diagnostics
> confirmed the current EASYLOAD chain dies before MAIN ever talks to Arduino, even with
> a Kernal-LOAD-friendly first-part PRG (`THE LAST NINJA.PRG`). Same first-part launches
> fine via direct menu selection (LoaderStub path).

## 0. Architectural reality check

The earlier informal sketch described Arduino "sending RL_STUB to $033C" and "patching $0330/$0331" as if Arduino had direct DMA access to C64 RAM. It does not — every RAM write reaches the C64 only by a PRG payload that the C64 itself decodes via the IRQLoader NMI stream. The IRQLoader has one rigid pipeline: 10 metadata bytes → 256-byte LoaderStub block → N pages of payload to a single contiguous address → `JMP $033C`.

Therefore "MultiLoad mode" must materialise as **a synthesised, self-installing prologue PRG** (call it the **MLBoot blob**) that the Arduino transmits in place of (or before) the first-part PRG. The blob contains the RL_STUB image, the RL_HANDLER image, the install code, and a Kernal LOAD chain to fetch the real first-part by name. From the user's perspective the brief still holds: select any PRG under `/MULTILOAD/`, the cartridge installs the resident hook, the game starts. The implementation just routes through one extra prologue.

Two viable shapes:

* **Shape A — static MLBoot blob in FlashLib.h.** A new tiny `MLBoot.s` (~1.1 KB) is built into a binary, embedded in FlashLib.h next to `stubData[]`, and transmitted by Arduino with a single name patch (the first-part filename). No 64tass step at runtime. No per-game template. This is what the brief implicitly asks for.
* **Shape B — Arduino synthesises bytes at runtime.** Drops the 64tass dependency for the blob but duplicates 6502 install logic in C — ugly and fragile. Reject.

**Plan adopts Shape A.**

## 1. Files to delete / modify / create

### Delete
| File | Why |
| --- | --- |
| `EasySD/Loader/Bridges/MultiLoad/MultiLoad.s` | Entire MAIN ($C000) is replaced by MLBoot. |
| `multiload/` (top-level dir, generated artefacts) | Per-game ZIPs no longer produced. |

### Modify
| File | Change |
| --- | --- |
| `EasySD/Loader/ResidentLoader.s` | Convert from `.include`-only to a **standalone-buildable** unit. Keep RL_STUB_IMAGE, RL_HANDLER_IMAGE and their `.logical $033C` / `.logical $E800` blocks **byte-identical**. Remove RL_INSTALL (move into MLBoot.s). Add at top: `.include "Common/System.inc"`, `.include "Common/EasySD.inc"`, plus the three `CARTRIDGENMIHANDLERX*` and `CARTRIDGE_BANK_VALUE` constants currently defined in `CartLibCommon.s:4-19`. (Needed for self-contained `64tass -b` build of the binary blob below.) Wrap the existing macros (e.g. `#WAITFOR`) as inline equivalents — RL already inlines `BIT/BVC` (ResidentLoader.s:621-623), so most macros are not used. Verify by grepping `#` macros in lines 488-812. |
| `Tools/build.py` | Remove `build_multiload()` (lines 726-750) and the `multiload` target (lines 1196-1198, 1026). In `build_core()`, after building LoaderStub (lines 640-643), add steps to: (a) `64tass -b` the new `MLBoot.s` → `build/MLBoot.bin`; (b) `bin2ardh(MLBoot.bin, build/MLBoot.h, "mlboot_len", "mlbootData")`; (c) include `MLBoot.h` bytes in the FlashLib.h concatenation alongside `defaultmenu.h` and `loaderstub.h` (lines 663-672). Drop `("Loader/Bridges/MultiLoad", "MultiLoad.s", "bootplugin")` row from `PLUGIN_MATRIX` (line 574). |
| `Tools/create_multiload.py` | Strip Sections D/F/H (template patching, ZIP build, legacy mode). Keep Sections A/B/C/E/G as a **disk-extractor only**: convert D64/D71/D81/T64 to a flat `MULTILOAD/<game>/` folder of PRGs (no EASYLOAD.PRG, no template patching). Default output is now a directory tree, not a ZIP. Update `--from-disk` to drop files into `multiload/<game>/`; drop `--first-part`, `--list-only` keeps working. Header comments updated. |
| `Arduino/EasySD/CartApi.cpp` | Add **MultiLoad-mode detection + MLBoot patch+transmit** in `LoadAndLaunchFile()` (line 1175). See section 5. |
| `Arduino/EasySD/FlashLib.h` (auto-generated) | Adds `mlboot_len` / `mlbootData[]` after `stubData[]`. Generated file — not hand-edited. |
| `EasySD/Loader/Common/System.inc` | Add a single new symbol `MLBOOT_FIRSTPART_OFFSET` (or just rely on a label exported in the listing file consumed by Python — see §3). Otherwise unchanged. |
| `Tools/build.py` `prebuild_checks()` | If `MLBoot.s` will include `Common/System.inc` directly, the existing CartZpMap/CartLibCommon include-count checks (lines 519-557) still pass because MLBoot.s does not need either. Verify after writing MLBoot.s that grep on it returns zero hits for `CartZpMap.inc` and `CartLibCommon.s`. |
| `EasySD/Loader/_archive/` | Move old `MultiLoad.s` here for reference rather than `git rm`, per project convention (other archived files exist). |
| `CLAUDE.md`, project memory `loader_paths.md`, `multiload_v2.md` | Update to reflect: ResidentLoader still exists, MAIN gone, MLBoot is the new prologue, EASYLOAD.PRG no longer produced. |

### Create
| File | Purpose |
| --- | --- |
| `EasySD/Loader/Bridges/MultiLoad/MLBoot.s` | New ~200 byte hand-written 6502 prologue. See §3. Replaces MultiLoad.s entirely. |
| (none new in Arduino/) | All Arduino changes are in CartApi.cpp + auto-generated FlashLib.h. |

## 2. Build chain for the embedded blob

Today, LoaderStub follows this flow (build.py:640-672):

```
LoaderStub.65s  →  64tass -b  →  build/LoaderStub.65s.bin  →  bin2ardh  →  build/LoaderStub.h  →  concat → Arduino/EasySD/FlashLib.h
```

The new blob follows the **same pattern** added next to it. `MLBoot.s` is a self-contained `*=$C000` source that `.include`s `ResidentLoader.s` (which by §1 becomes self-contained too) and emits a single linear binary. 64tass `-b` strips the load-address header so `bin2ardh` produces a `mlbootData[]` PROGMEM array. Arduino allocates flash for it (~1.1 KB — fits the release 7.5 KB / debug 2.7 KB headroom but **only just** in debug; verify after first build).

For the Python side to know where to write the per-launch first-part filename into the blob, MLBoot.s must export a stable label (e.g. `MLBOOT_FIRSTPART_LEN` and `MLBOOT_FIRSTPART_NAME`). Two options:

1. **Hardcode constant offsets** in MLBoot.s and mirror them in CartApi.cpp (same trick `create_multiload.py` uses today, OFFSET_LEN=4 etc.). One source of truth: keep them in `MLBoot.s` comments, copy as `#define` constants in CartApi.cpp.
2. **Parse the 64tass `--labels` output** in build.py and emit a `BlobOffsets.h` for Arduino. Slightly cleaner but adds a new build step.

Plan recommends **option 1** — six lines of constants, easy to keep in sync.

## 3. MLBoot.s — what it does

`*=$C000`, deliberately mirroring the old EASYLOAD load address so it won't collide with the typical $0801 BASIC area. Layout (keep these offsets stable; CartApi.cpp depends on them):

```
$C000   JMP MAIN                         ; 3 bytes
$C003   .byte VERSION (=4)               ; 1 byte sentinel for paranoia
$C004   MLBOOT_FIRSTPART_LEN  (.byte 0)  ; patched by Arduino per launch
$C005   MLBOOT_FIRSTPART_NAME (20 bytes, NUL-padded) ; patched
$C019   MAIN: ...
```

`MAIN` body (target ~80 bytes hand-coded):

1. `JSR RL_INSTALL` — exact same routine as current ResidentLoader.s:841-923, kept verbatim. Installs RL_STUB at $033C, RL_HANDLER+RL_MINI_CARTLIB at $E800, patches $0330/$0331, writes RL_NMI_REDIRECT to $FFFA/$FFFB.
2. **No PROT_StartTalking, no COMMAND_GET_PATH.** Skip the whole "talk to Arduino, fetch path, do custom load" block (MultiLoad.s:75-198). The bug is here; we do not reproduce it. Path-aware chdir is handled by `rl_chdir_to_game` which uses `RL_DIR_PATH` ($E840) — we leave that buffer empty (NUL-init). That makes `rl_chdir_to_game` take its early-return path (ResidentLoader.s:408-415): it just calls `RL_StartTalking` and returns C=0. **Arduino's CWD is whatever it was when LoadAndLaunchFile was called, which by `preserveLaunchPath` (CartApi.cpp:1188-1191) is `/MULTILOAD/<game>/` — exactly what we want.** Any in-game `LOAD "X",8,1` resolves relative to that CWD.
3. Set up filename pointer for Kernal LOAD: copy `MLBOOT_FIRSTPART_NAME` (length from `MLBOOT_FIRSTPART_LEN`) into `KERNAL_FILENAME_*` ($B7/$BB/$BC) area.
4. `LDA #1 / STA $B9` — secondary address 1 (use header load address).
5. `LDA #8 / STA $BA` — device 8.
6. `JSR $FFD5` (Kernal LOAD). This goes through `$0330/$0331` → which we just patched to RL_STUB → which calls RL_HANDLER → which talks to Arduino through the same RL_StartTalking path. The first-part PRG arrives in C64 RAM, RL_HANDLER returns end address in X/Y.
7. After LOAD returns: `STX $AE / STY $AF` (BASIC end-pointer registers). Then perform the **same LoaderStub-style launch dance** — copy the `SHOULD_RUN_BASIC` decision tree from LoaderStub.65s:109-135 verbatim (it's only ~25 bytes and self-contained), then either `JSR $A659 ; JMP $A7AE` (BASIC RUN) or `JMP ($00AE)` / `JMP ($008B)` (machine code). Set `$01=$37`, `$D011=$1B`, `$BA=$08`, `$DC0D=$81` first.
8. Error path: nothing fancy — `JMP ($A000)` cold start or `JMP $FCE2` reset. Acceptable because we have no menu to return to (the cartridge has been disabled).

Hardcoded length budget:
- RL_INSTALL ≈ 90 bytes (existing).
- MAIN body ≈ 80 bytes.
- RL_STUB_IMAGE = 52 bytes.
- RL_HANDLER_IMAGE ≈ 1024 bytes (currently fits in $E800-$EBFF window).
- Total blob ≈ **1.25 KB**.

`MLBoot.s` does **not** need CartLibStream/CartLibHi/CartLib/CartLibCommon at all — it never sends any commands itself. ResidentLoader's RL_MINI_CARTLIB inside the embedded handler image handles every `RL_*` call.

## 4. C64-side macro/include reorganisation for ResidentLoader.s

ResidentLoader.s today (line 50) declares:
> DEPENDENCIES: Constants from System.inc / EasySD.inc / CartZpMap.inc (via CartLibCommon.s)

In current MultiLoad.s these come transitively because `ResidentLoader.s` is included before `CartLibStream.s` (which transitively pulls CartLibCommon → System.inc + EasySD.inc + CartZpMap.inc). For standalone `MLBoot.s` use the include order must be:

```
MLBoot.s:
  .include "../../DebugMacros.s"
  .include "../../Common/System.inc"
  .include "../../Common/EasySD.inc"
  .include "../../CartZpMap.inc"
  ; CartLibCommon.s constants needed by RL_HANDLER:
  CARTRIDGENMIHANDLERX1 = $80AF
  CARTRIDGENMIHANDLERX4 = $80A0
  CARTRIDGENMIHANDLERX8 = $808C
  CARTRIDGE_BANK_VALUE  = $80AB
  ; (Mirror current CartLibCommon.s:4-19 so RL_NMITAB and RL_WaitProcessing
  ;  resolve under standalone build.)
  ...
  .include "../../ResidentLoader.s"
```

**Conflict guard**: `prebuild_checks()` in build.py:519-557 enforces "CartZpMap.inc included exactly once and only from CartLibStream.s; CartLibCommon.s included exactly once and only from CartLib.s; plugins must NOT include either directly". MLBoot.s lives under `Loader/Bridges/MultiLoad/`, **not** under `Plugins/`, so the plugin-include ban does not apply. But the global once-only check does. Three resolution options, in order of preference:

1. **Carve out a "CartZpMap.inc included from MLBoot.s OR CartLibStream.s" exception** in `prebuild_checks()` (cleanest for this plan).
2. **Refactor the include guard rule** to allow N includes if guarded by a sentinel — explicitly forbidden by CLAUDE.md ("Fix the include chain. Do not add include-guards.").
3. **Inline only the few ZP symbols MLBoot/RL actually use** (ZP_IRQ_API_*, ZP_LOADFILE_API_*, ZP_IRQ_TMP_SCRATCH, KERNAL_*) directly into MLBoot.s — no `.include "CartZpMap.inc"`. Tedious but keeps prebuild rules untouched.

Recommend **option 1**: relax the rule from "exactly 1" to "exactly 2 (CartLibStream.s and MLBoot.s)" or "from a known whitelist". One commit, well-localised diff in prebuild_checks().

## 5. Arduino-side detection and transmit logic

Edit `LoadAndLaunchFile()` (CartApi.cpp:1175). The brief asks: is the RL-image transmit BEFORE or AFTER the LoaderStub or PRG? Answer: **none of those** — the entire MLBoot blob is sent **instead of** the on-disk PRG, with the on-disk PRG name patched into the blob. The C64-side LoaderStub is sent unchanged (it does the end-pointer fix and JMPs to $C019 = MLBoot MAIN).

Concrete diff (pseudocode):

```cpp
void CartApi::LoadAndLaunchFile(const char* selectedFileName) {
  ...
  workingFile = sd.open(selectedFileName);
  if (!workingFile) { LOGE(SYS,"FILENOTFOUND!"); return; }

  // === NEW: MultiLoad-mode detection ===
  // launchPath at this point holds dirFunc.currentPath (preserveLaunchPath block, line 1188-1191).
  // Compare prefix case-insensitively.
  bool mlMode = (launchPath[0]=='/' && strncasecmp(launchPath+1,"MULTILOAD/",10)==0);
  if (mlMode) {
    LOG_ML_KV("MLMode launch: ", selectedFileName);
    workingFile.close();             // we will not stream this file directly
    SendMLBootBlob(selectedFileName); // see below
    Init();
    if (preserveLaunchPath) dirFunc.NavigateToPath(launchPath);
    cartInterface.StartListening();
    LOGI(ML, "MLBoot launched - C64 has resident loader installed");
    return;
  }
  // === END NEW ===

  // existing path unchanged from here ...
}
```

`SendMLBootBlob(const char* firstPartName)` (new private method, ~80 lines):

1. Validate filename length ≤ 20 incl. ".PRG"; LOGE+return on overflow.
2. Compute payload lengths exactly like the existing PRG path (CartApi.cpp:1213-1217): `transferLength = mlboot_len`, `transferPages`, `padBytes`. Note: `mlboot_len` already has the 2-byte load address removed if 64tass `-b` is used; double-check by looking at how `SendHeader()` consumes `low/high`.
3. Drive the existing reset/transfer pre-amble (CartApi.cpp:1218-1247): `ResetIndex / EnableCartridge / ResetC64 / delay(200)`, then `noInterrupts(); SendHeader(low=$00, high=$C0, ..., TYPE_STANDARD_PRG, TransferMode); SendLoaderStub();`.
4. Stream `mlbootData[]` from PROGMEM via `cartInterface.TransmitByteFast()`, **patching the filename field on-the-fly** at the bytes corresponding to `MLBOOT_FIRSTPART_LEN` (offset 4) and `MLBOOT_FIRSTPART_NAME` (offsets 5..24). For each byte index `i`: if `i==4`, transmit length byte; if 5≤i<5+nameLen, transmit name byte; if 5+nameLen≤i<25, transmit 0; else transmit `pgm_read_byte(mlbootData+i)`. Same simple loop the existing `SendLoaderStub()` uses.
5. Emit `padBytes` zeroes (CartApi.cpp:1263-1267).
6. `interrupts(); delayMicroseconds(30); cartInterface.DisableCartridge();`. Done.

Key safety: the on-disk first-part PRG is **not** opened or read by Arduino at this point — the C64 will request it shortly via the resident loader's `RL_OpenFile` call, which routes through Arduino's existing `HandleOpenFile` / `HandleReadFile`. CWD must be `/MULTILOAD/<game>/` at that moment, which is true because `preserveLaunchPath` re-navigates after `Init()`.

Flash budget check: roughly +1.1 KB for `mlbootData[]` + ~250 bytes new C++ in `SendMLBootBlob()`. Eats ~1.4 KB of the 7.5 KB release headroom; in DEBUG with 2.7 KB free, this leaves ~1.3 KB. **Tight but feasible** — verify with `--debug` build immediately after first compile.

## 6. Sequencing — ordered phases with intermediate buildable states

Each numbered phase ends with a green build. Hardware test points are flagged with [HW].

| Phase | What | Effort | Test |
| --- | --- | --- | --- |
| **P0** | Branch off `main`. Move current `MultiLoad.s` to `_archive/`. Make ResidentLoader.s self-contained: add the four `CARTRIDGE*` constants and the `.include "Common/System.inc"` / `EasySD.inc` / `CartZpMap.inc` lines at the top, guarded so existing MultiLoad include path (still in archive) doesn't double-include. Keep `PLUGIN_MATRIX` row alive — the plugin still builds against the archived source until P3. | 1 h | `python build.py plugins` succeeds. |
| **P1** | Write `MLBoot.s` (skeleton: `JMP MAIN`, version byte, name buffer, MAIN that just `JMP $FCE2` for now — proves the blob builds and lands at $C000). Add `64tass -b` step + `bin2ardh` step + FlashLib.h concat in `build.py:build_core()`. Rebuild Arduino. | 2 h | `python build.py core` produces `build/MLBoot.bin` and updated `Arduino/EasySD/FlashLib.h`. `arduino-compile` succeeds, sizes printed. |
| **P2** | Implement `SendMLBootBlob()` in CartApi.cpp + `/MULTILOAD/` detection in `LoadAndLaunchFile()`. Filename patching offsets hardcoded. Skip RL install in MLBoot for now — MAIN can simply load first-part by Kernal LOAD via `$0330` (ROM Kernal, no resident hook). [HW] Place a tiny test PRG (any single-PRG game) in `/MULTILOAD/SMOKE/` and try to launch via menu. Expected: PRG selection succeeds, blob arrives, Kernal LOAD runs through Arduino's existing `HandleOpenFile`, the test game starts. **No multi-load yet — just smoke-tests the synthesis pipeline.** | 3 h | Real-HW test [HW]. Serial: `MLMode launch: TEST.PRG` → `OpenFile: TEST.PRG` → game runs. |
| **P3** | Drop the `("Loader/Bridges/MultiLoad", ...)` row from PLUGIN_MATRIX. Delete `build_multiload()` and the `multiload` target. Strip `create_multiload.py` Sections D/F/H, change disk-extractor output to a folder tree under `multiload/<game>/`. Update `prebuild_checks()` whitelist to allow MLBoot.s including CartZpMap.inc. | 1.5 h | `python build.py release` succeeds; no `bootplugin.prg`, no `EASYLOAD.PRG` produced. |
| **P4** | Add the real RL_INSTALL call into `MLBoot.s` MAIN. Add the Kernal LOAD chain that loads the first-part name from the patched config block (so the loaded first-part now flows through RL_STUB → RL_HANDLER). Add SHOULD_RUN_BASIC + launch dance verbatim from LoaderStub.65s. [HW] Test with `/MULTILOAD/LASTNINJA1/THE LAST NINJA.PRG` from menu. Expected serial: `MLMode launch: THE LAST NINJA.PRG` → `OpenFile: THE LAST NINJA.PRG` → intro displays. | 4 h | Real-HW test [HW]. **Critical milestone** — proves resident hook installs correctly via the new path. |
| **P5** | Real multi-load test: navigate to level select, pick something that calls `LOAD "WILDERNESS",8,1`. Expected serial: `OpenFile: THE WILDERNESS.PRG`. Validates RL_HANDLER+rl_chdir_to_game still work in the new prologue context. | 1 h | Real-HW [HW]. |
| **P6** | Cleanup: remove the now-unreferenced ML_DEBUG_BORDERS define, remove archived MultiLoad.s if no longer wanted, update `CLAUDE.md` plugin matrix and the two memory files. Tag `v0.7-mlboot`. | 1 h | `python build.py release` clean. |

Total estimate: **~13 hours** of focused work, including the [HW] test cycles.

## 7. What to preserve verbatim

- `RL_STUB_IMAGE` block (ResidentLoader.s:68-122) — every byte. Eight V2 fixes + V2.1 early-passthrough are working hardware history. Touch only the surrounding `.include` directives.
- `RL_HANDLER_IMAGE` block (ResidentLoader.s:140-816), including `rl_main`, `rl_chdir_to_game`, the entire `RL_MINI_CARTLIB` (Send / SendBit / WaitProcessing / ReceiveFragmentNoCallback / SetName / OpenFile / CloseFile / GetInfoForFile / ReadFileNoCallback / SeekFile / LoadFileBySize / Start- and EndTalking / DisableInterrupts / NMITAB / WasteCertainTime / WasteTooMuchTime). All have proven hardware history for in-game LOAD interception.
- `RL_INSTALL` (ResidentLoader.s:841-923) — copy verbatim into MLBoot.s as a local routine, or keep at the bottom of ResidentLoader.s and call it from MLBoot.MAIN. Either way, no logic changes.
- LoaderStub.65s — **do not edit at all**. It is shared with non-MultiLoad PRG launches. The MLBoot blob's MAIN re-implements the same end-pointer / banking / SHOULD_RUN_BASIC logic locally; the LoaderStub at $033C does its usual job for the blob exactly as for any other PRG (set $AE/$AF, restore vectors, JMP ($008B) → $C019).

## 8. Testing strategy

Test PRG: `THE LAST NINJA.PRG` already deployed at `/MULTILOAD/LASTNINJA1/`. It is a Kernal-LOAD-friendly first-part that has been confirmed (see `multiload_v2.md`) to launch correctly through the existing LoaderStub direct-menu path. After refactor, expected serial trace at COM4 / 57600 with `LOG_ENABLE_ML=1`:

```
Launch: THE LAST NINJA.PRG
MLMode launch: THE LAST NINJA.PRG       ← new
Launched - C64 running game
OpenFile: THE LAST NINJA.PRG            ← issued by RL_HANDLER from $E800
ReadFile pages: N
... game intro ...
```

After level select:
```
OpenFile: THE WILDERNESS.PRG            ← second-part LOAD intercepted
ReadFile pages: M
```

Negative test: select any normal PRG **outside** `/MULTILOAD/` — must take the existing legacy path (no MLMode log line, no RL install). Confirms the path-prefix detection is correctly scoped.

VICE testing remains unreliable per CLAUDE.md (`PROT_WaitProcessing` becomes `CLC; RTS` in DEBUG=1). All [HW] checkpoints must be done on real C64 via `deploy-debug.bat`.

## 9. Risks / open questions to confirm before/during P1-P4

1. **Flash budget** — `mlbootData[]` is ~1.1 KB; the new `SendMLBootBlob()` may push ~250 B. Total ~1.4 KB. Verify after P1: if DEBUG build crosses 100% flash, drop `LOG_ENABLE_ML` from the debug build temporarily for the MLMode test or trim `RL_MINI_CARTLIB` (e.g. RL_SeekFile is currently always present even though only RL_LoadFileBySize uses it — could move RL_SeekFile inline).
2. **Where does the LoaderStub leave $AE/$AF?** LoaderStub copies `ACTUAL_END_LOW/HI` to $AE/$AF (LoaderStub.65s:50-57) — but our blob's payload end is at end-of-MLBoot ($C000+1.25KB ≈ $C500), which is wrong as a "BASIC end pointer". MLBoot MAIN must overwrite $AE/$AF (and $2D/$2F) with the real end address returned by RL_HANDLER's X/Y after the first-part LOAD. Also need to confirm SHOULD_RUN_BASIC, run on the blob's own header ($00 $C0), correctly takes the LAUNCH_MACHINE branch — yes it will (LoaderStub.65s:110-118), so JMP ($008B) → $C019 = MLBoot MAIN. Confirmed.
3. **CWD timing** — when MLBoot calls Kernal LOAD → RL_STUB → RL_HANDLER → `rl_chdir_to_game` → `RL_StartTalking` → emits handshake + COMMAND_GOTO_PATH, but `RL_DIR_PATH` ($E840) is empty (we chose to skip COMMAND_GET_PATH). The early-return branch fires; no chdir is sent; Arduino's CWD is whatever `LoadAndLaunchFile` left it as. After `Init()` (CartApi.cpp:1273) and `dirFunc.NavigateToPath(launchPath)` (line 1275), Arduino's CWD is `/MULTILOAD/<game>/` — exactly what we want for the resident hook's subsequent file accesses. **Verify** that `Init()` doesn't reset CWD before NavigateToPath runs — it calls `dirFunc.ReInit()` which does reset, but NavigateToPath restores. Trace the order carefully.
4. **First-part filename length** — `THE LAST NINJA.PRG` is 18 chars (incl ".PRG"). Within 20-char field. Document the limit prominently in the user-facing README; longer filenames must be truncated by `create_multiload.py` (it already does) or rejected at LoadAndLaunchFile time. Choose: rejection at Arduino with a serial error log is safer than silent truncation.
5. **Does Kernal LOAD with the resident hook installed actually work from MLBoot's $C000 context?** RL_STUB starts with `PHA / LDA $BA / CMP #8 / BEQ rl_stub_dev8 / PLA / JMP (RL_ORIG_VEC)`. We've patched $0330 to RL_STUB and $036B (RL_ORIG_VEC) to ROM Kernal. Device is set to 8. Runs through normal RL_HANDLER path. **Likely OK** but never tested — historically this code was only invoked by an in-game LOAD, not by a startup-time JSR $FFD5 from cartridge RAM. P4 [HW] is the proof.
6. **Interrupt state on entry to MLBoot** — the LoaderStub does `LDA #$1B / STA $D011` (VIC on) and `LDA #$81 / STA $DC0D` (CIA enable) before JMP ($008B). MLBoot MAIN immediately calls JSR RL_INSTALL which doesn't touch interrupts; then JSR LOAD which goes through RL_STUB → SEI in RL_StartTalking (RL_MINI_CARTLIB:661). Should be safe. Verify no IRQ fires between LoaderStub exit and the SEI inside RL_StartTalking — ~50 cycles of code, sub-jiffy, unlikely to matter.
7. **Backwards-compat with existing on-SD EASYLOAD.PRG files** — per requirements, none required. Old EASYLOAD.PRG files become inert files in `/MULTILOAD/<game>/` directories — they would be selectable in the menu and would launch via the **new** MLMode path (Arduino transmits MLBoot blob with "EASYLOAD.PRG" patched as the first-part name → blob does Kernal LOAD of EASYLOAD.PRG → that PRG loads at $C000 → its old MAIN runs → broken-as-before but harmlessly contained. No worse than today.) Document: "If MULTILOAD games on your SD card still have EASYLOAD.PRG, ignore or delete those files. Use the actual first-part PRG name instead."
8. **Does `dirFunc.NavigateToPath()` succeed for arbitrary `/MULTILOAD/X/` depth?** Existing path supports it (already used by current EASYLOAD.PRG flow). Should be no regression.

## 10. Critical files for implementation

- `EasySD/Loader/ResidentLoader.s`
- `EasySD/Loader/Bridges/MultiLoad/MLBoot.s` (new)
- `Arduino/EasySD/CartApi.cpp`
- `Tools/build.py`
- `EasySD/Loader/LoaderStub.65s` (read-only reference for SHOULD_RUN_BASIC + launch dance to copy verbatim into MLBoot.s)

---

## Magyar összefoglaló

A terv szerint a `MultiLoad.s MAIN` és a hozzá tartozó `EASYLOAD.PRG` template-rendszer megszűnik. Helyette egy új, kompakt 6502 prológus (`MLBoot.s`, kb. 200 byte kód + a változatlanul átemelt RL_STUB és RL_HANDLER képek, összesen kb. 1.25 KB) készül, amelyet a build-rendszer 64tass-szal fordít, `bin2ardh`-val PROGMEM tömbbé (`mlbootData[]`) alakít, és beemel a `FlashLib.h`-ba a meglévő `stubData[]` mintájára. Az Arduino oldalon a `LoadAndLaunchFile()` (CartApi.cpp:1175) felismeri a `/MULTILOAD/` útvonalprefixet és ilyenkor a kiválasztott PRG helyett a `mlbootData[]` blobot küldi át — a kívánt első-rész fájlnevet futás közben patcheli a blob 5–24. byte-jaiba. A C64 a már bevált LoaderStub-úton landol $C019-en (MLBoot MAIN), az ott telepíti a rezidens LOAD-hookot, majd Kernal LOAD-dal — ami most már a saját RL_STUB-on át megy — behúzza az igazi első részt és elindítja. Így megszűnik a jelenlegi MAIN duplikált, hibás logikája, eltűnik a `create_multiload.py` template-patchelése, a `build.py multiload` target, és a felhasználó simán bármelyik PRG-t választhatja a `/MULTILOAD/<game>/` mappából. A munka hat fázisra bontva, becslés szerint kb. 13 órányi fejlesztés, és minden fázis külön-külön is buildelhető, valódi C64-en tesztelhető állapotban hagyja a projektet.
