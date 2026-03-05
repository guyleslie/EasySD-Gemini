; ============================================================
; EasySD / IRQHack64 - Canonical Memory Map (High Memory Symbols)
; ============================================================
; Version: 2.0 (Updated 2025-12-30 - Sprint A.3.0)
;
; ⚠️ IMPORTANT: This file defines HIGH MEMORY addresses ($C000+),
;               NOT Zero Page ($00-$FF).
;               For Zero Page variables, see CartZpMap.inc
;
; This file provides OPTIONAL reference symbols for common memory regions.
; The CartLib API uses Zero Page pointers - buffers can be placed anywhere.
;
; Normative Reference: docs/MEMORY_MAP_CANONICAL.md v2.0 (Sprint A.3.0)
;
; Organization:
;   1. Transfer Buffer Reference ($C000-$C19F) - OPTIONAL
;   2. NMI Handler Region ($C1A0-$CEB6) - OPTIONAL
;   3. BurstLoader Buffer ($A000-$A18F) - Type B app only
;
; ============================================================

; ============================================================
; TRANSFER BUFFER REFERENCE - Optional Standardization ($C000-$C19F)
; ============================================================
;
; This symbol provides an OPTIONAL reference address for transfer buffers.
; Type A plugins may use this address for consistency, but it is NOT required.
;
; ARCHITECTURAL REALITY (Sprint A.3.0 findings):
;   - CartLib API uses Zero Page pointers ($69-$6A, $6C-$6D)
;   - Buffers can be placed ANYWHERE in available memory
;   - Current plugins use assembler auto-placement (e.g., $C670, $D032)
;   - NO technical requirement for fixed buffer addresses
;
; BUFFER CHARACTERISTICS:
;   - VOLATILE: Content is NOT preserved across API calls
;   - Ownership: Caller owns during API call, INVALID after return
;   - Size: 416 bytes recommended minimum for file metadata
;
; USAGE (OPTIONAL):
;   .include "CartMemoryMap.inc"
;   *=TRANSFER_BUFFER_ADDR      ; Optional explicit placement
;   FileInfoBuffer: .res TRANSFER_BUFFER_SIZE
;
;   OR (RECOMMENDED - assembler auto-placement):
;   .include "CartMemoryMap.inc"
;   FileInfoBuffer: .res 416    ; Assembler places after code
;
; Reference: docs/MEMORY_MAP_CANONICAL.md v2.0 Section 1.1
; ============================================================

; Standard transfer buffer (416 bytes)
TRANSFER_BUFFER_ADDR     = $C000  ; Base address (NOT Zero Page!)
TRANSFER_BUFFER_SIZE     = $01A0  ; 416 bytes ($C000-$C19F)
TRANSFER_BUFFER_END      = $C19F  ; Last byte of buffer

; ============================================================
; NMI HANDLER REGION - Optional Interrupt Code Space ($C1A0-$CEB6)
; ============================================================
;
; This symbol provides an OPTIONAL reference region for NMI handlers.
; Most Type A plugins do NOT use NMI handlers (use standard API instead).
;
; CHARACTERISTICS:
;   - Size: 3351 bytes (sufficient for complex NMI handler tables)
;   - Position: Historically after $C000 buffer (now optional)
;   - Usage: RARE (most plugins use IRQ_ReceiveFragment API)
;
; ACTUAL USAGE:
;   - Type A plugins: Rarely use NMI (standard API preferred)
;   - BurstLoader (Type B app): Uses custom NMI, but loads at $080E
;
; Usage Example (OPTIONAL):
;   *=NMI_HANDLER_REGION_START
;   MyNMIHandler:
;       ; ... NMI code ...
;       RTI
;
; Reference: docs/MEMORY_MAP_CANONICAL.md v2.0 Section 1.2
; ============================================================

NMI_HANDLER_REGION_START = $C1A0  ; First byte of NMI region
NMI_HANDLER_REGION_END   = $CEB6  ; Last byte of NMI region
NMI_HANDLER_REGION_SIZE  = $0D17  ; 3351 bytes

; ============================================================
; BURSTLOADER BUFFER - Type B Standalone Application ($A000-$A18F)
; ============================================================
;
; ⚠️ ARCHITECTURAL CLARIFICATION (Sprint A.3.0) ⚠️
;
; BurstLoader is a TYPE B STANDALONE APPLICATION (loads at $080E),
; NOT a Type A plugin. It uses $A000-$A18F for its transfer buffer.
;
; This is NOT an "exception" - Type B apps have full memory freedom.
;
; ARCHITECTURAL CATEGORY:
;   - Type: Standalone Application (Type B)
;   - Load Address: $080E (replaces menu entirely)
;   - Exit Method: IRQ_ExitToMenu (requests menu reload)
;   - Memory Ownership: Full $080E-$FFFF (no menu cohabitation)
;
; RATIONALE FOR $A000 BUFFER:
;   - Purpose: Real-time video streaming application
;   - Design Choice: Optimized memory layout for 50+ NMI handlers
;   - Performance: NMI handlers perform inline cartridge reads to $A000
;                  for maximum throughput (400 bytes/frame)
;
; TYPE A vs TYPE B DISTINCTION:
;   - Type A Plugins: Load at $C000+, return to menu (RTS)
;   - Type B Apps: Load at $080E, replace menu, exit via IRQ_ExitToMenu
;
; APPLICABILITY:
;   - This symbol is for BurstLoader ONLY (Type B app)
;   - Type A plugins: Use assembler auto-placement (recommended)
;   - New Type B apps: May use any buffer address (full memory freedom)
;
; Usage Example (BurstLoader.s):
;   ;----------------------------------------------------------------------------------------------------------
;   ; BurstLoader - Real-Time Video Streaming Application
;   ; ARCHITECTURE: Type B Standalone Application (loads at $080E, replaces menu)
;   ; Reference: docs/MEMORY_MAP_CANONICAL.md v2.0 Section 4.2-4.3
;   ;----------------------------------------------------------------------------------------------------------
;   .include "../../Loader/CartMemoryMap.inc"
;   TRANSFERBUFFER = $A000  ; Type B app - memory freedom
;   *=$080E                  ; Type B entry point
;   ; ...
;
; Reference: docs/MEMORY_MAP_CANONICAL.md v2.0 Section 4.2-4.3
; ============================================================

; BurstLoader exception buffer (400 bytes)
BURST_BUFFER_ADDR        = $A000  ; BurstLoader ONLY (NOT Zero Page!)
BURST_BUFFER_SIZE        = $0190  ; 400 bytes ($A000-$A18F)
BURST_BUFFER_END         = $A18F  ; Last byte of BurstLoader buffer

; ============================================================
; USAGE NOTES (v2.0)
; ============================================================
;
; 1. Including this file is OPTIONAL:
;      .include "../../Loader/CartMemoryMap.inc"
;      Symbols are provided for consistency, but NOT required.
;
; 2. Buffer placement strategies (BOTH VALID):
;      ✅ OPTION A (Assembler auto-placement - RECOMMENDED):
;         FileBuffer: .res 416    ; Assembler places after code
;
;      ✅ OPTION B (Explicit placement - optional consistency):
;         *=TRANSFER_BUFFER_ADDR
;         FileBuffer: .res TRANSFER_BUFFER_SIZE
;
; 3. API usage (MANDATORY - uses ZP pointers):
;      #SETADDR FileBuffer, ZP_IRQ_API_DATA_LO
;      JSR IRQ_ReadFileNoCallback
;
; 4. Compile-time safety checks (RECOMMENDED):
;      .if * > $DF00
;          .error "Plugin overflow! Would overlap with I/O region."
;      .endif
;
; 5. For Zero Page API parameters, see CartZpMap.inc (mandatory for API)
;
; ============================================================

; ============================================================
; CROSS-REFERENCES (v2.0)
; ============================================================
;
; Normative Documents:
;   - docs/MEMORY_MAP_CANONICAL.md v2.0 (ZP pointer architecture)
;   - docs/IO2_PROTOCOL_SPECIFICATION.md v1.0 (Streaming protocol)
;   - docs/ZP_GUIDELINES.md (Zero Page API parameters)
;   - docs/sprints/A.3.0_PLUGIN_ARCHITECTURE_RESEARCH.md (Type A/B categories)
;   - docs/sprints/A.3.0_REFACTORING_DECISION.md (NO-GO decision)
;
; Related Implementation Files:
;   - CartZpMap.inc (Zero Page API parameters $64-$95 - MANDATORY for API)
;   - BurstLoader/MemUsage.txt (Type B app design spec)
;
; Version History:
;   - v1.0 (2025-12-29): Initial version with fixed buffer requirement
;   - v2.0 (2025-12-30): Corrected to reflect ZP pointer architecture
;                        (Sprint A.3.0 research findings)
;
; ============================================================
