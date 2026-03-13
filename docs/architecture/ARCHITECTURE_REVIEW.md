# EasySD : A Deep-Dive Technical Analysis

This document provides a deep-dive technical review of the EasySD project. The analysis covers the C64-side 6502 assembly codebase and the Arduino-side C++ firmware, with the goal of assessing the system's architecture, correctness, and overall engineering quality.

## 1. Executive Summary

The EasySD system is **exceptionally well-engineered** for a hobbyist retro-computing project. It demonstrates a rare combination of deep platform-specific knowledge and modern software architecture principles.

The design is not merely functional; it is built to be **robust, maintainable, and extensible**. The code is clean, well-structured, and shows a clear separation of concerns. The few minor issues identified are limitations inherent to the platform or conscious design trade-offs, not critical bugs. The system's correctness is well-established through its sound logic and strict adherence to C64 platform conventions.

---

## 2. Architectural Overview: A Client-Server Model

The system is designed as a classic client-server architecture, which is a perfect fit for the hardware configuration:

*   **C64 (The Client/Master):** The C64 runs the main user-facing application (the menu) and various plugins. It acts as the "master" in the relationship, initiating all commands (e.g., "read this file," "list this directory").

*   **Arduino (The Server/Slave):** The Arduino microcontroller acts as a dedicated "file server." Its sole responsibility is to manage the SD card and respond to commands sent by the C64. It never initiates communication, only replies.

This model smartly delegates tasks: the resource-constrained Arduino handles the complexities of the FAT filesystem, while the C64 (with its more flexible memory and processing power) handles the application logic, user interface, and program execution.

---

## 3. Component Deep-Dive

### 3.1. Low-Level Communication Layer (`CartLib` ↔ `CartApi`)

The communication protocol is the heart of the system and is implemented symmetrically on both the C64 and Arduino.

*   **C64-to-Arduino (Master to Slave):**
    *   **Mechanism:** A custom, software-driven serial protocol implemented in `CartLib.s`. It uses timing variations (a form of Pulse-Width Modulation) to encode `1`s and `0`s by toggling an I/O address.
    *   **Assessment:** This is a clever hardware-less solution. The code correctly disables interrupts (`SEI`) during transmission to ensure the sensitive timing is not disrupted. This is a fragile but effective technique when hardware UARTs are not available.

*   **Arduino-to-C64 (Slave to Master):**
    *   **Mechanism:** A much faster, hardware-assisted protocol. The Arduino places a byte on the data bus and triggers a Non-Maskable Interrupt (NMI) on the C64. A custom NMI handler on the C64 (`TransferHandler`) immediately reads the byte and stores it in memory.
    *   **Assessment:** This is a standard and high-performance technique for fast data transfer on the C64. Using the NMI ensures that data is received with the highest priority, minimizing the chance of corruption.

*   **Protocol Flow:** The overall command-and-response flow (Handshake -> Command -> Arguments -> Response) is well-defined and consistently implemented in `HandleApi` on the Arduino side and through the various `IRQ_*` calls on the C64 side.

**Conclusion:** The communication layer is **correct and robust**. It uses platform-appropriate techniques and the implementation is clean and symmetrical on both ends.

### 3.2. High-Level Abstractions

#### Directory Navigation (`DirFunction` & Menu Logic)

The system uses a **single-source-of-truth model** for navigating the directory hierarchy, with the Arduino as the authoritative owner of the current path.

*   **Mechanism:**
    1.  The Arduino maintains the full current path in `currentPath` (a 64-byte string). It is the sole owner of filesystem state.
    2.  When a user enters a directory, a single `CHANGE_DIR` command is sent to the Arduino, which updates `currentPath` accordingly.
    3.  When a user goes back (`..`), a single `".."` command is sent to the Arduino. `GoBack()` truncates `currentPath` to the parent and calls `sd.chdir(parentAbsPath)`. No path replay is needed.
    4.  For display (header row) and plugin path building, the C64 sends `COMMAND_GET_PATH` (command 9) and receives the current path as a 256-byte page (64-byte path + zero padding) into a scratch buffer (`PLUGIN_HEADER`), then copies the result into `PATHBUFFER`. This is handled by `IRQ_GetCurrentPath` in `EasySDMenu.s`.
    5.  `ExtractLastDirname` extracts the last path component from `PATHBUFFER` to populate `NAMELOW`/`NAMEHIGH` when needed.

*   **Note on SdFat 2.x:** Professional C64 projects such as SD2IEC and Pi1541 use ChaN's FatFS library, which natively resolves `f_chdir("..")` through the FAT dotdot cluster chain. SdFat 2.x does not handle `".."` the same way in its path parser, so the Arduino side maintains an explicit `currentPath` string and uses absolute-path navigation for `GoBack()`. This is the correct workaround for the library in use.

*   **Assessment:** The model is **clean and unambiguous**. Eliminating the C64-side `DIRSTACK` mirror removes an entire class of synchronisation bugs — the path can never diverge between the two sides. The cost is one extra `COMMAND_GET_PATH` round-trip when the header row is rendered, which is negligible at the NMI transfer rate.

#### File Loading (`LoadFileBySize`)

This centralized function in `CartLibHi.s` is a cornerstone of the project's modern architecture.

*   **Mechanism:** It abstracts the entire file loading process. It takes a file size and skip-byte count, handles seeking past headers, calculates the correct number of pages to read (using a mathematically sound rounding algorithm: `(payload + 255) / 256`), and performs the blocking read.
*   **Assessment:** This function is **excellently implemented**. It replaces brittle, error-prone manual calculations in multiple places with a single, robust, and reusable function. Its adoption in the Menu and various plugins significantly improves the reliability and maintainability of the entire project.

#### P2TK — Phase 2 Transfer Kernel (`KernalBridge.s`)

PRG files that extend into `$C000+` would overwrite the running `KernalBridge` code during loading. P2TK solves this with a three-phase approach:

*   **Phase 1:** Load `STARTADDR → $BFFF` via the normal `LoadFileBySize` call (skip 2-byte PRG header).
*   **Phase 2:** Relocate an NMI wait-stub to `$033B` (the `FILE_PATH_BUF` area, which is free at this point), switch `$01 = $34` (all RAM — `$D000–$FFFF` writable), and stream `$C000+` via NMI at `$80AF`.
*   **Phase 3 (conditional):** If the data fills `$FF00–$FFFF`, an intercept handler at `$036A` captures the tail bytes (`$FFFA–$FFFF`) into `TAIL_BUF` (`$03BB–$03C0`) to prevent mid-transfer corruption of the active NMI vector. The tail bytes are written after the transfer completes.
*   Data tables for Phase 3 (`P3_TAIL_CODE`/`P3_HANDLER`) are stored in the `KernalBridge` gap at `$C003/$C02A` — always-readable RAM that avoids the VIC-II I/O space overflow problem.

### 3.3. Application & Dispatch Logic (`EasySDMenu.s`)

The main menu program ties all the components together.

*   **Main Loop:** A standard, efficient event-driven loop that handles keyboard input and music playback without conflicts.
*   **Plugin Dispatch System:** The logic for launching plugins is a highlight of the architecture.
    *   It uses a clear, **convention-over-configuration** approach: to handle `.koa` files, it looks for a plugin at `/PLUGINS/KOAPLUGIN.BIN` (or `.PRG`).
    *   This makes the system predictable and easy for users to manage.
    *   The fallback from `.bin` (loaded with the new, robust loader) to `.prg` is a flexible design choice.
*   **Built-in plugins:** PRG launcher, KOA viewer (Koala Painter), PETG viewer (PETSCII art), WAV player (IO2 streaming ~13.5 KB/s), MUS player (SID music), and **CvdPlayer** — an NMI-driven CVD (Commodore Video Digital) format player for full-motion video. CVD files are produced by `Tools/cvd_convert.py`. The player uses `READCART_MODULATED` triggered at `STARTRASTER=241` rather than IO2 streaming.
*   **Assessment:** The application logic is **robust and well-structured**. It correctly separates concerns, gracefully handles different file types, and provides a clear path for future expansion.

### 3.4. Debug & Test Infrastructure

The project includes a substantial debug and test infrastructure that runs the same production code paths under VICE emulation.

*   **CartLibDebug.s:** Provides a `$CF00–$CF4F` dump area visible in the VICE monitor. Stores loader state, error codes, and break-point sentinels for interactive debugging.

*   **EasySDMenuMock.s** (included when `DEBUG=1`): A C64-side mock of the Arduino API, enabling VICE emulator testing without real hardware.
    *   `MOCK_CURRENT_PATH` — a live 65-byte buffer mirroring the format of Arduino's `currentPath` (`"/"`, `"/games"`, `"/games/demos"` — no trailing slash except root).
    *   `MOCK_GetCurrentPath` — simulates `COMMAND_GET_PATH`; copies `MOCK_CURRENT_PATH` into `PATHBUFFER`, making the mock transparent to callers.
    *   `MOCK_EnterDir` — increments `DIRLEVEL` (capped at 2 for the three mock directories), then appends the selected dirname to `MOCK_CURRENT_PATH` with correct `'/'` separator logic.
    *   `MOCK_GoBack` — decrements `DIRLEVEL` and truncates `MOCK_CURRENT_PATH` to its parent path, exactly mirroring Arduino's `GoBack()`.
    *   `SETDIR1/2/3` — reproduce Arduino's `HandleReadDirectory` wire protocol by copying hardcoded directory blocks into the `DIRLOAD` area.
    *   **Key design principle:** only the path-fetch step differs between debug and release (one JSR). `PRINTDIRHEADER` and `PrepareFileNameParameter` run the same logic (`ExtractLastDirname`, path-append) in both modes.

*   **test_vice_menu.py:** Six automated navigation tests executed via VICE's binary monitor protocol (TCP port 6510).
    *   Tests: `INIT`, `NAV_DOWN`, `NAV_UP`, `NAV_WRAP`, `ENTER_DIR`, `GO_BACK`
    *   Verifies cursor movement, directory entry, directory header update, and go-back behaviour using memory reads against defined sentinel addresses.

---

## 4. Identified Strengths & Professional Practices

*   **Architectural Patterns:** The project correctly uses modern design patterns, including the **Wrapper/Implementation** pattern (`SafeStream`) to create a stable API, and centralized memory mapping (`CartZpMap.inc`) to prevent Zero Page conflicts.
*   **Two-tier macro system:** Assembly-time abstractions are organised in two layers:
    *   **Tier 1 — `SystemMacros.s`** (included automatically via `CartLib.s`): Hardware-access patterns shared across the whole codebase — `READCART`, `READCART_MODULATED`, `SETBANK`, `SAVEREGS`/`RESTOREREGS`, `WAITFOR`.
    *   **Tier 2 — `APIMacros.s`** (explicit include at plugin top): High-level API wrappers — `OPENFILE`, `GETFILEINFO`, `EXTRACTFILESIZE`, `CLOSEFILE`, `SETADDR`. Kept separate to avoid duplicate-macro errors in 64tass and to signal intentional API-level use.
*   **Code Quality (DRY Principle):** The centralization of debug macros (`DebugMacros.s`) and strings (`DebugStrings.s`) demonstrates a professional commitment to the "Don't Repeat Yourself" principle, which drastically improves maintainability.
*   **Robustness & Correctness:** The code shows a deep understanding of the C64 platform. The KERNAL-replacement routines in `KernalBridge.s` correctly handle I/O status flags, and the graphics plugins correctly manage VIC-II state. This indicates that solutions are based on research and platform knowledge, not assumptions.

---

## 5. Minor Considerations

The analysis found no critical bugs. The following are minor architectural limitations or potential areas for future polish:

*   **16-bit Payload Calculation:** The `LoadFileBySize` function currently uses 16-bit arithmetic to calculate the payload size (`file_size - skip_bytes`). While the API supports a 32-bit file size, this calculation limits the function to files under 64KB. This is perfectly acceptable for any C64 use case but could be documented with a source code comment for clarity.
*   **Path Length Limit:** The effective path length limit is now 64 characters, imposed by the Arduino's `currentPath` buffer. This replaces the former C64-side `PATH_MAX` of 96 characters. 64 characters is sufficient for typical SD card directory depths; deeply-nested paths with long directory names would silently truncate on the Arduino side.

These points are observations, not flaws, and do not detract from the high quality of the project.
