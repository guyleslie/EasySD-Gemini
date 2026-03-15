;================================================================================
; ResidentLoader.s — Multi-Load Resident LOAD Hook
;================================================================================
;
; PURPOSE:
;   Intercepts C64 Kernal LOAD ($FFD5) for device 8 and serves files from
;   the SD card via EasySD.  Enables classic multi-load games that use
;   LOAD "PART",8,1 between game sections.
;
; COMPONENTS:
;   A) RL_STUB image  — 20-byte trampoline copied to $033C.
;      Patches $0330/$0331 so every JSR $FFD5 arrives here.
;   B) RL_HANDLER image — handler copied to $E800.
;      Runs with $01=$35 (RAM under Kernal visible, I/O active).
;      Calls CartLib routines in the BOOT.PRG $C000 area (always-accessible RAM).
;      NOTE V1 LIMITATION: if a game part loads into $C000+, subsequent CartLib
;      calls will call into game code instead.  Fix in V2: embed mini-CartLib.
;   C) RL_INSTALL — run once by BOOT.PRG to copy images and patch the vector.
;
; MEMORY LAYOUT (constants defined in Common/System.inc):
;   $0330/$0331   Kernal LOAD vector        → patched to $033C (RL_STUB)
;   $033C         RL_STUB code (20 bytes)
;   $035C         RL_ORIG_VEC (2 bytes)     backup of original $0330/$0331
;   $035E         RL_SAVED_01 (1 byte)      game's $01 saved during hook
;   $E800         RL_HANDLER entry point    (handler image copied here)
;   $E840         RL_DIR_PATH (64 bytes)    reserved for future chdir support
;   $E880         RL_FNAME_BUF (36 bytes)   assembled filename
;   $E8A4         RL_FILEINFO_BUF (32 bytes) FAT directory entry
;   $E8C4         RL_HDR_BUF (256 bytes)    first-page read buffer
;
; USAGE:
;   .include "ResidentLoader.s"    ; from MultiLoad.s, before CartLibStream.s
;
; DEPENDENCIES:
;   CartLib + CartLibHi (included by MultiLoad.s after this file — forward refs ok)
;   Constants from System.inc / CartZpMap.inc (pulled in via CartLibCommon.s chain)
;
; AUTHOR: Claude Sonnet 4.6 (Sprint 14)
; DATE: 2026-03-15
;================================================================================


;================================================================================
; Section A: RL_STUB image
; .logical $033C — labels resolve at $033C for correct runtime operation.
; Physical bytes sit here in the BOOT.PRG binary; RL_INSTALL copies them.
;================================================================================

RL_STUB_IMAGE:
.logical $033C

; Entry point — Kernal LOAD vector ($0330/$0331) redirected here.
; A = secondary address on entry (pushed, restored, returned to caller).
; $01 is saved, switched to $35, handler called, then restored.
RL_STUB_ENTRY:
	PHA
	LDA PROCESSOR_PORT
	STA RL_SAVED_01
	LDA #PP_CONFIG_RAM_ON_ROM
	STA PROCESSOR_PORT
	JSR RL_HANDLER
	LDA RL_SAVED_01
	STA PROCESSOR_PORT
	PLA
	RTS

.here
RL_STUB_IMAGE_END:
RL_STUB_IMAGE_SIZE = RL_STUB_IMAGE_END - RL_STUB_IMAGE


;================================================================================
; Section B: RL_HANDLER image
; .logical $E800 — all labels inside resolve at $E800+ for runtime correctness.
; Physical bytes stored in BOOT.PRG binary; RL_INSTALL copies to $E800 RAM.
; (Writes always reach RAM regardless of $01; reads need $01=$35 to see them.)
;
; JSRs to CartLib routines (IRQ_StartTalking etc.) use $C000+ addresses —
; resolved as forward references after CartLibStream.s is included.
;================================================================================

RL_HANDLER_IMAGE:
.logical $E800

;----------------------------------------------
; RL_HANDLER — entry point at $E800
; Called by RL_STUB with $01=$35 already active.
;----------------------------------------------
; NOTE: branch distances inside this block can exceed 127 bytes.
; Build with --long-branch to auto-expand them.
RL_HANDLER:
	LDA KERNAL_DEVICE_NUMBER
	CMP #8
	BEQ rl_dev8_ok
	JMP rl_passthru         ; not device 8 — forward to original LOAD
rl_dev8_ok:
	JMP rl_main

;----------------------------------------------
; Data areas — allocated within handler image.
; Labels resolve at their $E800+ logical addresses.
; RL_INSTALL copies these 0-initialised .fill bytes along with the code.
;----------------------------------------------

; RL_DIR_PATH: reserved 64-byte game directory path (V2: chdir per LOAD call)
rl_dir_path_area:
	.fill 64

; RL_FNAME_BUF: assembled filename (KERNAL name + ".PRG", max 36 bytes + null)
rl_fname_area:
	.fill 36

; RL_FILEINFO_BUF: 32-byte FAT directory entry returned by IRQ_GetInfoForFile
rl_fileinfo_area:
	.fill 32

; RL_HDR_BUF: first-page read buffer (2-byte PRG header + 254 bytes of data)
rl_hdr_area:
	.fill 256

;----------------------------------------------
; rl_main — main handler logic
;
; Arduino is already in the game directory because the user navigated
; there before selecting BOOT.PRG; it stays there between IRQ_StartTalking
; sessions (no chdir needed for V1).
;
; ZP scratch: $8B/$8C = copy ptr, $8D/$8E = end addr temps
;             $8E also used as fname length temp (re-used after fname is done)
;----------------------------------------------
rl_main:
	JSR IRQ_StartTalking

	;--- Build filename: copy KERNAL name then append ".PRG" if absent ---
	LDX KERNAL_FILENAME_LENGTH
	LDY #0
rl_copy_fname:
	LDA (KERNAL_FILENAME_LOW), Y
	STA rl_fname_area, Y
	INY
	DEX
	BNE rl_copy_fname
	; Y = length of original filename

	STY $8E                 ; save length

	; Check for existing ".PRG" (dot at Y-4, 'P' at Y-3, 'R' at Y-2, 'G' at Y-1)
	CPY #4
	BCC rl_append_prg

	TYA
	SEC
	SBC #4
	TAX                     ; X = index of potential '.'

	LDA rl_fname_area, X
	CMP #'.'
	BNE rl_restore_append
	INX
	LDA rl_fname_area, X
	CMP #'P'
	BNE rl_restore_append
	INX
	LDA rl_fname_area, X
	CMP #'R'
	BNE rl_restore_append
	INX
	LDA rl_fname_area, X
	CMP #'G'
	BNE rl_restore_append
	LDY $8E                 ; already has .PRG — restore Y (length)
	JMP rl_fname_done

rl_restore_append:
	LDY $8E
rl_append_prg:
	LDA #'.'
	STA rl_fname_area, Y
	INY
	LDA #'P'
	STA rl_fname_area, Y
	INY
	LDA #'R'
	STA rl_fname_area, Y
	INY
	LDA #'G'
	STA rl_fname_area, Y
	INY
rl_fname_done:
	LDA #0
	STA rl_fname_area, Y    ; null-terminate (safety; IRQ_SetName uses length)
	; Y = final filename length (without null)

	;--- Open file ---
	TYA
	LDX #<rl_fname_area
	LDY #>rl_fname_area
	JSR IRQ_SetName
	LDX #$01
	JSR IRQ_OpenFile
	BCC rl_opened_ok
	JMP rl_error_talking    ; open failed, no file to close
rl_opened_ok:

	;--- Get file size from FAT directory entry ---
	LDA #<rl_fileinfo_area
	STA ZP_IRQ_API_DATA_LO
	LDA #>rl_fileinfo_area
	STA ZP_IRQ_API_DATA_HI
	LDY #$00
	JSR IRQ_GetInfoForFile
	BCC rl_info_ok
	JMP rl_error_opened
rl_info_ok:

	LDA rl_fileinfo_area + 28
	STA ZP_LOADFILE_API_SIZE0
	LDA rl_fileinfo_area + 29
	STA ZP_LOADFILE_API_SIZE1
	LDA rl_fileinfo_area + 30
	STA ZP_LOADFILE_API_SIZE2
	LDA rl_fileinfo_area + 31
	STA ZP_LOADFILE_API_SIZE3

	;--- Read first page: PRG 2-byte header + up to 254 data bytes ---
	LDA #<rl_hdr_area
	STA ZP_IRQ_API_DATA_LO
	LDA #>rl_hdr_area
	STA ZP_IRQ_API_DATA_HI
	LDA #1
	STA ZP_IRQ_API_DATA_LENGTH
	LDY #$00
	JSR IRQ_ReadFileNoCallback
	BCC rl_read_ok
	JMP rl_error_opened
rl_read_ok:

	; Store load_addr in $8B/$8C for indirect writes
	LDA rl_hdr_area
	STA $8B
	LDA rl_hdr_area + 1
	STA $8C

	; Branch on file size: small (<= 255 bytes) vs big (>= 256 bytes)
	LDA ZP_LOADFILE_API_SIZE1
	BNE rl_big_file

	; Small file (SIZE_HI = 0, SIZE <= 255): copy only SIZE-2 data bytes
	SEC
	LDA ZP_LOADFILE_API_SIZE0
	SBC #2
	BCC rl_after_load       ; SIZE < 2 — header only
	BEQ rl_after_load       ; SIZE = 2 — no data bytes
	TAX
	LDY #0
rl_copy_small:
	LDA rl_hdr_area + 2, Y
	STA ($8B), Y
	INY
	DEX
	BNE rl_copy_small
	JMP rl_after_load

rl_big_file:
	; SIZE >= 256: copy first 254 data bytes, then load remainder via LoadFileBySize
	LDY #0
rl_copy_254:
	LDA rl_hdr_area + 2, Y
	STA ($8B), Y
	INY
	CPY #254
	BNE rl_copy_254

	; Setup LoadFileBySize: target = load_addr+254, skip = $0100 (256)
	CLC
	LDA rl_hdr_area
	ADC #254
	STA ZP_IRQ_API_DATA_LO
	LDA rl_hdr_area + 1
	ADC #0
	STA ZP_IRQ_API_DATA_HI

	LDA #$00
	STA ZP_LOADFILE_API_SKIP_LO
	LDA #$01
	STA ZP_LOADFILE_API_SKIP_HI

	JSR LoadFileBySize
	BCC rl_after_load
	JMP rl_error_opened

rl_after_load:
	;--- Compute end address = load_addr + file_size - 2 ---
	CLC
	LDA rl_hdr_area
	ADC ZP_LOADFILE_API_SIZE0
	STA $8D
	LDA rl_hdr_area + 1
	ADC ZP_LOADFILE_API_SIZE1
	STA $8E

	SEC
	LDA $8D
	SBC #2
	TAX                     ; X = end_lo
	LDA $8E
	SBC #0
	TAY                     ; Y = end_hi

	JSR IRQ_CloseFile
	JSR IRQ_EndTalking
	CLC                     ; success: C=0, X=end_lo, Y=end_hi
	RTS

;--- Error handlers ---
rl_error_opened:
	JSR IRQ_CloseFile
rl_error_talking:
	JSR IRQ_EndTalking
	SEC
	RTS

;--- Pass-through: device != 8 — jump to original Kernal LOAD ---
rl_passthru:
	JMP (RL_ORIG_VEC)       ; indirect jump through $035C

.here
RL_HANDLER_IMAGE_END:
RL_HANDLER_IMAGE_SIZE = RL_HANDLER_IMAGE_END - RL_HANDLER_IMAGE


;================================================================================
; Section C: RL_INSTALL
; Runs at $C000+ in normal $01=$37 context.
; Called once by BOOT.PRG before jumping to the game.
;
; Actions:
;   1. Copy RL_STUB image  → $033C (writes always reach RAM regardless of $01).
;   2. Copy RL_HANDLER image → $E800 (same — writes always go to RAM).
;   3. Save original $0330/$0331 to RL_ORIG_VEC ($035C).
;   4. Patch $0330/$0331 to point at RL_STUB ($033C).
;
; Registers: all preserved.
; ZP scratch: $8B-$8E (free per CartZpMap.inc).
;================================================================================

RL_INSTALL:
	PHA
	TXA
	PHA
	TYA
	PHA

	;--- 1. Copy RL_STUB image to $033C ---
	; RL_STUB_IMAGE_SIZE <= 32 bytes — a single-page Y loop suffices.
	LDY #0
rl_inst_stub_loop:
	LDA RL_STUB_IMAGE, Y
	STA RL_STUB, Y
	INY
	CPY #RL_STUB_IMAGE_SIZE
	BNE rl_inst_stub_loop

	;--- 2. Copy RL_HANDLER image to $E800 (multi-page) ---
	LDA #<RL_HANDLER_IMAGE
	STA $8B
	LDA #>RL_HANDLER_IMAGE
	STA $8C
	LDA #<RL_HANDLER
	STA $8D
	LDA #>RL_HANDLER
	STA $8E

	LDX #>RL_HANDLER_IMAGE_SIZE     ; number of full 256-byte pages
	BEQ rl_inst_partial
rl_inst_page_loop:
	LDY #0
rl_inst_page_byte:
	LDA ($8B), Y
	STA ($8D), Y
	INY
	BNE rl_inst_page_byte
	INC $8C
	INC $8E
	DEX
	BNE rl_inst_page_loop

rl_inst_partial:
	LDX #<RL_HANDLER_IMAGE_SIZE     ; remaining bytes (low byte = size mod 256)
	BEQ rl_inst_vec
	LDY #0
rl_inst_partial_loop:
	LDA ($8B), Y
	STA ($8D), Y
	INY
	DEX
	BNE rl_inst_partial_loop

rl_inst_vec:
	;--- 3. Backup original $0330/$0331 ---
	LDA $0330
	STA RL_ORIG_VEC
	LDA $0331
	STA RL_ORIG_VEC + 1

	;--- 4. Patch $0330/$0331 to point to RL_STUB ---
	LDA #<RL_STUB
	STA $0330
	LDA #>RL_STUB
	STA $0331

	PLA
	TAY
	PLA
	TAX
	PLA
	RTS
