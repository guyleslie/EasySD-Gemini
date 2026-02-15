# Changelog

All notable changes to the **EasySD / IRQHack64** project are documented in this file.

This changelog follows the principles of **Keep a Changelog**, adapted to a
**phase-based development model**.

---

## [Phase 2A] – Stabilization Phase
**Period:** 2025-12-17 → 2025-12-19  
**Status:** ✅ CLOSED – Hardware-test ready

Phase 2A focused exclusively on **correctness, stability, and build discipline**
before any real hardware testing.

---

### 2025-12-17
#### Fixed
- Identified multiple **duplicate symbol** issues caused by repeated includes
  in the loader and plugin build chain.
- Detected invalid usage of `.ifndef / .ifnconst` patterns (unsupported by 64tass).

---

### 2025-12-18
#### Changed
- Introduced **single-source-of-truth include ownership**:
  - `CartZpMap.inc` owned exclusively by `CartLibStream.s`
  - `CartLibCommon.s` owned exclusively by `CartLib.s`
- Removed all unsafe include-guard hacks.

#### Added
- **Wrapper-based include hierarchy** for loader components.
- Initial design of **PreBuild fail-fast validation**.

#### Fixed
- Resolved crashes and undefined behavior caused by ZP map redefinition.
- Corrected invalid assembler directives incompatible with 64tass.

---

### 2025-12-18 (later)
#### Added
- **PetsciiDisplayer size-based loading design**
  - Planned migration away from fixed-page (`IRQ_DATA_LENGTH`) loading.

#### Changed
- Defined a unified **plugin lifecycle model** (entry / exit responsibilities).

---

### 2025-12-19
#### Added
- **PreBuild.bat fail-fast validation**
  - Build aborts on illegal include chains.
- **Modular build system**
  - `build_core.bat`
  - `build_plugins_all.bat`
  - `build_plugin_*.bat` (per plugin)
- **Unified DEBUG / RELEASE build mode**
  - Single `DEBUG` environment variable respected by all plugins.

#### Changed
- **PetsciiDisplayer migrated to LoadFileBySize**
  - FAT file size validation added.
  - Fixed-page loading fully removed.
- **Plugin clean-return logic unified**
  - MUS / WAV / PETSCII now:
    - save state on entry
    - stop IRQ/CIA/VIC cleanly
    - restore state
    - exit exclusively via menu control

#### Fixed
- Plugins returning via `RTS` instead of controlled menu exit.
- WAV player infinite-loop exit behavior.
- DEBUG builds silently skipping MUS/WAV plugins.
- Outdated build scripts missing active plugins.

#### Removed
- Fixed-length PETSCII loading assumptions.
- Implicit, undocumented build steps.
- Legacy build messages referring to non-existent plugins.

---

### Stability Summary (Phase 2A)
- Loader include order is deterministic and enforced.
- All plugins build consistently in DEBUG and RELEASE modes.
- Plugin exit behavior is predictable and safe.
- Emulator (VICE) regression testing is now a valid baseline.

---

## [Phase 2B] – Hardware Validation (Planned)
- Real hardware smoke testing
- ROML / ROMH / IRQ validation
- SD-card golden image verification
- Arduino firmware ↔ loader protocol validation

---

_End of Changelog_
