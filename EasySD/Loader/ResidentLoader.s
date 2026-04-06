;================================================================================
; ResidentLoader.s — Multi-Load Resident LOAD Hook (V2)
;================================================================================
;
; PURPOSE:
;   Intercepts C64 Kernal LOAD ($FFD5) for device 8 and serves files from
;   the SD card via EasySD.  Enables classic multi-load games that use
;   LOAD "PART",8,x between game sections.
;
; V2 CHANGES (fixes 5 V1 bugs):
;   1. Extended RL_STUB saves X/Y for SA=0 (MEMUSS) support.
;   2. RL_NMI_REDIRECT at $0368: JMP ($0318) written to $FFFA/$FFFB by
;      RL_INSTALL so NMI dispatch works correctly under $01=$35.
;   3. SA=0 support: handler checks $B9 and uses RL_SAVED_X/Y as load target.
;   4. Embedded RL_MINI_CARTLIB at $EA00 — NO #SETBANK anywhere.
;      Games loading to $C000+ no longer break the hook.
;   5. chdir safety: rl_chdir_to_game sends COMMAND_GOTO_PATH before each LOAD.
;
; COMPONENTS:
;   A) RL_STUB_IMAGE — 52-byte trampoline copied to $033C.
;      Patches $0330/$0331 so every JSR $FFD5 arrives here.
;      Saves X, Y, $01; switches to $35; calls handler; restores all.
;   B) RL_HANDLER_IMAGE — handler+mini-CartLib copied to $E800-$EBFF.
;      Runs entirely with $01=$35 (Kernal RAM visible, ROML accessible).
;      Calls only RL_MINI_CARTLIB routines (at $EA00+) — never $C000+ CartLib.
;   C) RL_INSTALL — run once by BOOT.PRG to copy images and install hooks.
;
; MEMORY LAYOUT (constants in Common/System.inc):
;   $0330/$0331   Kernal LOAD vector       → patched to $033C (RL_STUB)
;   $033C-$035B   RL_STUB code (32 bytes)
;   $035C-$0367   padding (zero-filled, 12 bytes)
;   $0368-$036A   RL_NMI_REDIRECT: JMP ($0318) — written to $FFFA/$FFFB
;   $036B-$036C   RL_ORIG_VEC (2 bytes)     backup of original $0330/$0331
;   $036D         RL_SAVED_01 (1 byte)      game's $01 during hook
;   $036E         RL_SAVED_X  (1 byte)      game's X at LOAD call (SA=0)
;   $036F         RL_SAVED_Y  (1 byte)      game's Y at LOAD call (SA=0)
;   $E800         RL_HANDLER entry point
;   $E840         RL_DIR_PATH (64 bytes)    game directory for chdir safety
;   $E880         RL_FNAME_BUF (36 bytes)   assembled filename
;   $E8A4         RL_FILEINFO_BUF (32 bytes) FAT directory entry
;   $E8C4         RL_HDR_BUF (256 bytes)    first-page read buffer
;   $EA00         RL_MINI_CARTLIB base      embedded CartLib (no #SETBANK)
;
; DEPENDENCIES:
;   Constants from System.inc / EasySD.inc / CartZpMap.inc (via CartLibCommon.s)
;
; AUTHOR: Claude Sonnet 4.6 (Sprint 15 — V2)
; DATE: 2026-03-16
;================================================================================


;================================================================================
; Section A: RL_STUB_IMAGE
; .logical $033C — labels resolve at $033C for correct runtime operation.
; Physical bytes sit here in the BOOT.PRG binary; RL_INSTALL copies them.
;
; Entry: A = secondary address on entry (same as Kernal LOAD convention).
; The stub saves X (MEMUSS lo for SA=0), Y (MEMUSS hi for SA=0), and $01,
; switches banking to $35 (Kernal RAM visible), calls RL_HANDLER, then
; restores everything before RTS back to the game.
;================================================================================

RL_STUB_IMAGE:
.logical $033C

RL_STUB_ENTRY:
	PHA                         ; save A (secondary address from Kernal call)
	STX RL_SAVED_X              ; save X (= MEMUSS lo if SA=0)
	STY RL_SAVED_Y              ; save Y (= MEMUSS hi if SA=0)
	LDA PROCESSOR_PORT
	STA RL_SAVED_01
	LDA #PP_CONFIG_RAM_ON_ROM   ; $35: Kernal RAM visible, ROML accessible
	STA PROCESSOR_PORT
	JSR RL_HANDLER              ; → $E800 (now in RAM, accessible with $01=$35)
	LDA RL_SAVED_01
	STA PROCESSOR_PORT          ; restore game's banking
	LDX RL_SAVED_X
	LDY RL_SAVED_Y
	PLA
	RTS

; Ensure stub code ends by $035B (32 bytes max from $033C)
.if * > $035C
	.error "RL_STUB code exceeds $035B — reduce stub size"
.endif

; --- padding to $035C ---
.fill $035C - *, $00

; --- RL_NMI_REDIRECT at $0368 ---
; JMP ($0318): on NMI with $01=$35, CPU reads $FFFA/$FFFB from RAM (written
; by RL_INSTALL), arrives here, then dispatches via SOFTNMIVECTOR → $80AF.
; Label NOT redefined here — RL_NMI_REDIRECT = $0368 lives in System.inc.
.fill $0368 - *, $00
	JMP ($0318)                 ; 3 bytes: $6C $18 $03

; --- metadata cells at $036B-$036F ---
; Labels NOT redefined here — RL_ORIG_VEC/$SAVED_01/X/Y live in System.inc.
; These bytes are initialised on copy; RL_INSTALL / RL_STUB overwrite at runtime.
	.byte $00, $00             ; $036B-$036C: RL_ORIG_VEC placeholder
	.byte $37                  ; $036D: RL_SAVED_01 placeholder (default $01=$37)
	.byte $00                  ; $036E: RL_SAVED_X placeholder
	.byte $00                  ; $036F: RL_SAVED_Y placeholder

.here
RL_STUB_IMAGE_END:
RL_STUB_IMAGE_SIZE = RL_STUB_IMAGE_END - RL_STUB_IMAGE


;================================================================================
; Section B: RL_HANDLER_IMAGE
; .logical $E800 — all labels resolve at $E800+ for runtime correctness.
; Physical bytes stored in BOOT.PRG binary; RL_INSTALL copies to $E800 RAM.
;
; Runs entirely with $01=$35:
;   - $E000-$FFFF is RAM   (Kernal ROM hidden — handler code lives here)
;   - $8000-$9FFF is ROML  (cartridge ROM accessible — TransferHandler OK)
;   - $D000-$DFFF is I/O   (CIA/VIC registers accessible — CHAREN=1)
;
; ALL CartLib calls go to RL_MINI_CARTLIB ($EA00+) — NEVER to $C000+ CartLib.
; ZP scratch: $8B/$8C = copy ptr or temp addr; $8D/$8E = end addr temps.
;================================================================================

RL_HANDLER_IMAGE:
.logical $E800

;----------------------------------------------
; RL_HANDLER — entry point at $E800
; Called by RL_STUB with $01=$35 already active.
;----------------------------------------------
RL_HANDLER:
	LDA KERNAL_DEVICE_NUMBER    ; $BA
	CMP #8
	BEQ rl_dev8_ok
	JMP rl_passthru             ; not device 8 — forward to original Kernal LOAD
rl_dev8_ok:
	JMP rl_main

;----------------------------------------------
; Data areas — fixed addresses within handler image.
; Uses .fill padding to reach exact RL_* constants from System.inc.
;----------------------------------------------

; align to RL_DIR_PATH = $E840
.fill $E840 - *, $00

; RL_DIR_PATH: null-terminated game directory path (max 64 bytes)
; Written by BOOT.PRG MAIN (via COMMAND_GET_PATH) on install.
; Read by rl_chdir_to_game before every SD file access.
rl_dir_path_area:
	.fill 64

; RL_FNAME_BUF: assembled filename — KERNAL name + ".PRG" (max 36 bytes + null)
rl_fname_area:
	.fill 36

; RL_FILEINFO_BUF: 32-byte FAT directory entry from RL_GetInfoForFile
rl_fileinfo_area:
	.fill 32

; RL_HDR_BUF: first-page read buffer (2-byte PRG header + 254 bytes of data)
rl_hdr_area:
	.fill 256

;----------------------------------------------
; rl_main — main handler logic
; Entered from rl_dev8_ok after device check.
; $01=$35 throughout — restored by RL_STUB on return.
;----------------------------------------------
rl_main:
	; chdir to game directory before every access (safety against Arduino CWD drift)
	JSR rl_chdir_to_game
	BCS rl_error_pre_talking    ; chdir failed, session wasn't started

	;--- Build filename: copy KERNAL name then append ".PRG" if absent ---
	LDX KERNAL_FILENAME_LENGTH
	LDY #0
rl_copy_fname:
	LDA (KERNAL_FILENAME_LOW), Y
	STA rl_fname_area, Y
	INY
	DEX
	BNE rl_copy_fname
	; Y = original filename length

	STY $8E                     ; save length

	; Check for existing ".PRG" suffix (need at least 4 chars)
	CPY #4
	BCC rl_append_prg

	TYA
	SEC
	SBC #4
	TAX                         ; X = index of potential '.'

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
	LDY $8E                     ; already has .PRG — restore Y
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
	STA rl_fname_area, Y        ; null-terminate
	; Y = final filename length (without null)

	;--- Set filename and open file ---
	TYA
	LDX #<rl_fname_area
	LDY #>rl_fname_area
	JSR RL_SetName
	LDX #$01
	JSR RL_OpenFile
	BCC rl_opened_ok
	JMP rl_error_talking        ; open failed, EndTalking still needed
rl_opened_ok:

	;--- Get file size ---
	LDA #<rl_fileinfo_area
	STA ZP_IRQ_API_DATA_LO
	LDA #>rl_fileinfo_area
	STA ZP_IRQ_API_DATA_HI
	LDY #$00
	JSR RL_GetInfoForFile
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

	;--- Read first 256-byte page (PRG header + up to 254 data bytes) ---
	LDA #<rl_hdr_area
	STA ZP_IRQ_API_DATA_LO
	LDA #>rl_hdr_area
	STA ZP_IRQ_API_DATA_HI
	LDA #1
	STA ZP_IRQ_API_DATA_LENGTH
	LDY #$00
	JSR RL_ReadFileNoCallback
	BCC rl_hdr_ok
	JMP rl_error_opened
rl_hdr_ok:

	;--- Determine load target address ---
	; SA=0: load target comes from X/Y at call time (saved in RL_SAVED_X/Y).
	;       The file still has a 2-byte header on disk but it is skipped;
	;       we already read it into rl_hdr_area[0..1] — just don't use it.
	; SA=1: load target is the PRG header bytes [0..1].
	LDA KERNAL_SECONDARY_ADDRESS  ; $B9
	BNE rl_use_header_addr

	; SA=0: use RL_SAVED_X/Y
	LDA RL_SAVED_X
	STA $8B
	LDA RL_SAVED_Y
	STA $8C
	JMP rl_addr_known

rl_use_header_addr:
	; SA=1 (or any non-zero): use PRG file header
	LDA rl_hdr_area
	STA $8B
	LDA rl_hdr_area + 1
	STA $8C

rl_addr_known:
	; $8B/$8C = load target address

	;--- Copy/load data ---
	; Branch on file size: small (<=255 bytes total) vs large (>=256 bytes)
	LDA ZP_LOADFILE_API_SIZE1
	BNE rl_big_file

	; Small file: copy (SIZE-2) data bytes from header buffer
	SEC
	LDA ZP_LOADFILE_API_SIZE0
	SBC #2
	BCC rl_after_load           ; SIZE < 2 — header only
	BEQ rl_after_load           ; SIZE = 2 — no data bytes
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
	; Large file: copy first 254 data bytes, then load remainder via RL_LoadFileBySize
	LDY #0
rl_copy_254:
	LDA rl_hdr_area + 2, Y
	STA ($8B), Y
	INY
	CPY #254
	BNE rl_copy_254

	; Setup RL_LoadFileBySize: target = load_addr+254, skip=$0100 (already read 256)
	CLC
	LDA $8B
	ADC #254
	STA ZP_IRQ_API_DATA_LO
	LDA $8C
	ADC #0
	STA ZP_IRQ_API_DATA_HI

	LDA #$00
	STA ZP_LOADFILE_API_SKIP_LO
	LDA #$01
	STA ZP_LOADFILE_API_SKIP_HI

	JSR RL_LoadFileBySize
	BCC rl_after_load
	JMP rl_error_opened

rl_after_load:
	;--- Compute end address = load_addr + file_size - 2 ---
	CLC
	LDA $8B
	ADC ZP_LOADFILE_API_SIZE0
	STA $8D
	LDA $8C
	ADC ZP_LOADFILE_API_SIZE1
	STA $8E

	SEC
	LDA $8D
	SBC #2
	TAX                         ; X = end_lo
	LDA $8E
	SBC #0
	TAY                         ; Y = end_hi

	JSR RL_CloseFile
	JSR RL_EndTalking           ; NO #SETBANK — $01=$35 preserved for RL_STUB
	CLC                         ; success: C=0, X=end_lo, Y=end_hi
	RTS

;--- Error handlers ---
rl_error_opened:
	JSR RL_CloseFile
rl_error_talking:
	JSR RL_EndTalking           ; NO #SETBANK
rl_error_pre_talking:
	SEC
	RTS

;--- Pass-through: device != 8 — jump to original Kernal LOAD ---
rl_passthru:
	JMP (RL_ORIG_VEC)           ; indirect jump through $036B

;----------------------------------------------
; rl_chdir_to_game
; Sends COMMAND_GOTO_PATH with the stored RL_DIR_PATH so the Arduino
; navigates to the game directory before each file access.
; Skipped (CLC + RTS) if rl_dir_path_area[0] == $00 (not yet set).
;
; Saves/restores KERNAL_FILENAME_* so the caller's filename state is intact.
; Returns: C=0 success (session open), C=1 error.
; ZP scratch: $8B/$8C (free per CartZpMap.inc $8B-$8E range).
;----------------------------------------------
rl_chdir_to_game:
	; Skip if path not set
	LDA rl_dir_path_area
	BNE rl_chdir_do
	; Path empty — still need to start talking for subsequent file ops
	JSR RL_StartTalking
	CLC
	RTS

rl_chdir_do:
	; Save KERNAL filename state to ZP scratch
	LDA KERNAL_FILENAME_LENGTH
	STA $8B
	LDA KERNAL_FILENAME_LOW
	STA $8C
	LDA KERNAL_FILENAME_HIGH       ; must save: RL_SetName will overwrite $BC
	STA $8D                        ; $BC is the hi-byte of the indirect ZP pointer

	; Count null-terminated path length
	LDY #0
rl_path_len:
	LDA rl_dir_path_area, Y
	BEQ rl_path_len_done
	INY
	CPY #64
	BNE rl_path_len
rl_path_len_done:
	; Y = path length

	; Set name to rl_dir_path_area
	TYA
	LDX #<rl_dir_path_area
	LDY #>rl_dir_path_area
	JSR RL_SetName

	; Start talking, send COMMAND_GOTO_PATH + filename
	JSR RL_StartTalking
	LDA #COMMAND_GOTO_PATH
	JSR RL_Send
	JSR RL_SendFileName
	JSR RL_WaitProcessing
	BCS rl_chdir_err

	; Restore KERNAL filename state
	LDA $8B
	STA KERNAL_FILENAME_LENGTH
	LDA $8C
	STA KERNAL_FILENAME_LOW
	LDA $8D
	STA KERNAL_FILENAME_HIGH
	CLC
	RTS

rl_chdir_err:
	LDA $8B
	STA KERNAL_FILENAME_LENGTH
	LDA $8C
	STA KERNAL_FILENAME_LOW
	LDA $8D
	STA KERNAL_FILENAME_HIGH
	JSR RL_EndTalking
	SEC
	RTS

;================================================================================
; RL_MINI_CARTLIB — Embedded CartLib (follows handler code, ~$EA00-$ECXX)
; Address is not fixed; nothing calls it directly — all calls use RL_* labels.
;
; CRITICAL: NO #SETBANK ANYWHERE in this section.
; All routines are exact copies of the CartLib originals with:
;   - PROT_ prefix → RL_ prefix
;   - All #SETBANK PP_CONFIG_DEFAULT lines REMOVED
;   - PROT_ReceiveFragmentNoCallback: $01=$35 OK because RL_INSTALL has written
;     RL_NMI_REDIRECT to $FFFA/$FFFB — NMI dispatch works under $01=$35.
;   - NMITAB, WasteCertainTime, WasteTooMuchTime, PROT_SendBit, etc. all copied.
;
; TransferHandler is at $80AF (ROML — accessible with $01=$35 because LORAM=1).
;================================================================================

;--- Timing helpers (copied verbatim from CartLib.s) ---

RL_WasteCertainTime:
-
	DEX
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	;
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	BNE -
	RTS

RL_WasteTooMuchTime:
	LDX #1
RL_OUTERWASTE:
	LDY #$FF
-
	DEY
	NOP
	BNE -
	DEX
	BNE RL_OUTERWASTE
	RTS

;--- Bit sender ---
RL_SendBit:
	JSR RL_WasteTooMuchTime
	LSR
	BCC +
	LDX #12
	BNE RL_SB_continue
+
	LDX #6
RL_SB_continue:
	LDY MODULATION_ADDRESS
	JSR RL_WasteCertainTime
	LDY MODULATION_ADDRESS
	RTS

;--- Byte sender ---
; Saves/restores X, Y. Uses ZP_IRQ_TMP_SCRATCH ($77).
RL_Send:
	STA ZP_IRQ_TMP_SCRATCH
	TXA
	PHA
	TYA
	PHA
	LDA ZP_IRQ_TMP_SCRATCH
	JSR RL_SendBit
	JSR RL_SendBit
	JSR RL_SendBit
	JSR RL_SendBit
	JSR RL_SendBit
	JSR RL_SendBit
	JSR RL_SendBit
	JSR RL_SendBit
	PLA
	TAY
	PLA
	TAX
	RTS

;--- NMITAB: low bytes of NMI handler addresses (must match CartLib.s NMITAB) ---
RL_NMITAB:
	.byte <CARTRIDGENMIHANDLERX1, <CARTRIDGENMIHANDLERX4, <CARTRIDGENMIHANDLERX8

;--- Interrupt disable helpers ---
RL_DisableVICInterrupts:
	ASL VIC_INT_ACK
	LDA #$00
	STA VIC_INT_CONTROL
	RTS

RL_DisableCIAInterrupts:
	LDA #$7F
	STA CIA_1_BASE + CIA_INT_MASK
	STA CIA_2_BASE + CIA_INT_MASK
	LDA CIA_1_BASE + CIA_INT_MASK
	LDA CIA_2_BASE + CIA_INT_MASK
	RTS

RL_DisableInterrupts:
	JSR RL_DisableVICInterrupts
	JSR RL_DisableCIAInterrupts
	RTS

;--- RL_ReceiveFragmentNoCallback ---
; NO #SETBANK: RL_INSTALL has written RL_NMI_REDIRECT ($0368) to $FFFA/$FFFB.
; With $01=$35 (HIRAM=0): reads from $FFFA/$FFFB see RAM → RL_NMI_REDIRECT →
;   JMP ($0318) → TransferHandler at $80AF (in ROML, accessible).
; With $01=$37: reads from $FFFA/$FFFB see Kernal ROM ($FE43) → JMP ($0318).
; Both cases dispatch correctly — no #SETBANK needed.
;
; Setup: ZP_IRQ_API_DATA_LO/HI = target; ZP_IRQ_API_DATA_LENGTH = page count.
; Y in: transfer mode (0=x1, 1=x4, 2=x8).
RL_ReceiveFragmentNoCallback:
	JSR RL_DisableInterrupts
	LDA RL_NMITAB, Y
	STA SOFTNMIVECTOR
	LDA #$80                    ; high byte of $8000 (ROML — TransferHandler)
	STA SOFTNMIVECTOR + 1

	LDA #$00
	STA ZP_IRQ_STATE_WAITHANDLE

	; NO #SETBANK here (V2 change — NMI works via RAM $FFFA vector under $01=$35)

	LDX ZP_IRQ_API_DATA_LENGTH
	LDY #$00

	CLV
	; #WAITFOR ZP_IRQ_STATE_WAITHANDLE, BVC — expanded inline:
-
	BIT ZP_IRQ_STATE_WAITHANDLE
	BVC -

	LDA #0
	CLC
	RTS

;--- RL_WaitProcessing ---
; Polls CARTRIDGE_BANK_VALUE ($80AB = ROML, accessible with $01=$35 / LORAM=1).
; NO #SETBANK — not needed (ROML always visible when LORAM=1).
; Returns C=0 on success ($80+), C=1 on error.
RL_WaitProcessing:
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
-
	LDA CARTRIDGE_BANK_VALUE
	BEQ -
	BPL +
	CLC
	RTS
+
	SEC
	RTS

;--- RL_StartTalking ---
; Wakes Arduino. SEI + disable interrupts + send handshake bytes.
RL_StartTalking:
	SEI
	JSR RL_DisableInterrupts
	LDA #$64
	JSR RL_Send
	LDA #$46
	JSR RL_Send
	LDA #$17
	JSR RL_Send
	RTS

;--- RL_EndTalking ---
; NO #SETBANK — $01=$35 preserved throughout handler, restored by RL_STUB.
RL_EndTalking:
	LDA #COMMAND_END_TALKING
	JSR RL_Send
	SEI
	JSR RL_DisableCIAInterrupts
	; NO #SETBANK PP_CONFIG_DEFAULT here
	CLI
	RTS

;--- RL_SetName ---
; In: A=length, X=addrLO, Y=addrHI
RL_SetName:
	STA KERNAL_FILENAME_LENGTH
	STX KERNAL_FILENAME_LOW
	STY KERNAL_FILENAME_HIGH
	RTS

;--- RL_SendFileName ---
RL_SendFileName:
	LDA KERNAL_FILENAME_LENGTH
	JSR RL_Send
	LDX KERNAL_FILENAME_LENGTH
	LDY #$00
-
	LDA (KERNAL_FILENAME_LOW), Y
	JSR RL_Send
	INY
	DEX
	BNE -
	RTS

;--- RL_OpenFile ---
; In: X=flags (1=read). Returns C=0 ok, C=1 error.
RL_OpenFile:
	LDA #COMMAND_OPEN_FILE
	JSR RL_Send
	TXA
	JSR RL_Send
	JSR RL_SendFileName
	JSR RL_WaitProcessing
	RTS

;--- RL_CloseFile ---
RL_CloseFile:
	LDA #COMMAND_CLOSE_FILE
	JSR RL_Send
	JSR RL_WaitProcessing
	RTS

;--- RL_GetInfoForFile ---
; Returns 256 bytes (32 bytes FAT entry + padding) at ZP_IRQ_API_DATA_LO/HI.
RL_GetInfoForFile:
	LDA #COMMAND_GET_INFO_FOR_FILE
	JSR RL_Send
	JSR RL_WaitProcessing
	BPL +
	LDA #$01
	STA ZP_IRQ_API_DATA_LENGTH
	JMP RL_ReceiveFragmentNoCallback
+
	RTS

;--- RL_ReadFileNoCallback ---
; Reads ZP_IRQ_API_DATA_LENGTH pages to ZP_IRQ_API_DATA_LO/HI.
; Y=0 on entry (transfer mode x1).
RL_ReadFileNoCallback:
	LDA #COMMAND_READ_FILE
	JSR RL_Send
	LDA ZP_IRQ_API_DATA_LENGTH
	JSR RL_Send
	JSR RL_WaitProcessing
	BPL +
	JMP RL_ReceiveFragmentNoCallback
+
	RTS

;--- RL_SeekFile ---
; In: X=direction (SEEK_DIRECTION_START=0, etc.)
;     ZP_IRQ_API_SEEK_LO/HI = 16-bit offset
RL_SeekFile:
	LDA #COMMAND_SEEK_FILE
	JSR RL_Send
	TXA
	JSR RL_Send
	LDA ZP_IRQ_API_SEEK_LO
	JSR RL_Send
	LDA ZP_IRQ_API_SEEK_HI
	JSR RL_Send
	JSR RL_WaitProcessing
	RTS

;--- RL_LoadFileBySize ---
; Seeks past skip bytes then reads payload pages.
; Setup: ZP_LOADFILE_API_SIZE0..3, ZP_LOADFILE_API_SKIP_LO/HI,
;        ZP_IRQ_API_DATA_LO/HI = target address.
; Returns C=0 ok, C=1 error.
RL_LoadFileBySize:
	; Step 1: seek if skip > 0
	LDA ZP_LOADFILE_API_SKIP_LO
	ORA ZP_LOADFILE_API_SKIP_HI
	BEQ RL_LFB_no_seek

	LDA ZP_LOADFILE_API_SKIP_LO
	STA ZP_IRQ_API_SEEK_LO
	LDA ZP_LOADFILE_API_SKIP_HI
	STA ZP_IRQ_API_SEEK_HI
	LDX #SEEK_DIRECTION_START
	JSR RL_SeekFile
	BCS RL_LFB_Error

RL_LFB_no_seek:
	; Step 2: payload = file_size - skip (16-bit, ignores size2/3)
	SEC
	LDA ZP_LOADFILE_API_SIZE0
	SBC ZP_LOADFILE_API_SKIP_LO
	STA ZP_LOADFILE_API_PAYLOAD_LO
	LDA ZP_LOADFILE_API_SIZE1
	SBC ZP_LOADFILE_API_SKIP_HI
	STA ZP_LOADFILE_API_PAYLOAD_HI

	; Step 3: page count = ceil(payload / 256)
	LDA ZP_LOADFILE_API_PAYLOAD_LO
	CLC
	ADC #$FF
	LDA ZP_LOADFILE_API_PAYLOAD_HI
	ADC #$00
	STA ZP_IRQ_API_DATA_LENGTH

	; Step 4: read
	BEQ RL_LFB_Done             ; 0 pages → nothing to read
	LDY #$00
	JSR RL_ReadFileNoCallback
	BCS RL_LFB_Error

RL_LFB_Done:
	CLC
	RTS

RL_LFB_Error:
	SEC
	RTS

.here
RL_HANDLER_IMAGE_END:
RL_HANDLER_IMAGE_SIZE = RL_HANDLER_IMAGE_END - RL_HANDLER_IMAGE


;================================================================================
; Section C: RL_INSTALL / RL_UNINSTALL
; Both run at $C000+ in normal $01=$37 context.
;
; RL_INSTALL (call once on entry):
;   1. Copy RL_STUB_IMAGE  → $033C (writes always reach RAM, $01-independent).
;   2. Copy RL_HANDLER_IMAGE → $E800 (same — writes go to RAM regardless of $01).
;   3. Write RL_NMI_REDIRECT address ($0368) to $FFFA/$FFFB (RAM NMI vector).
;   4. Backup original $0330/$0331 → RL_ORIG_VEC ($036B).
;   5. Patch $0330/$0331 → RL_STUB ($033C).
;
; RL_UNINSTALL (call on error exit, before returning to menu):
;   Restores $0330/$0331 from RL_ORIG_VEC ($036B).
;   Without this, every subsequent LOAD goes through the resident stub
;   (which has no valid game context) and PRG loading breaks until power cycle.
;   The NMI vector ($FFFA/$FFFB RAM) is left as-is: with $01=$37 the CPU reads
;   the NMI vector from Kernal ROM ($FE43), so the RAM values are irrelevant.
;
; Registers: all preserved (both routines).
; ZP scratch: $8B-$8E (free per CartZpMap.inc $8B-$8E range).
;================================================================================

RL_INSTALL:
	PHA
	TXA
	PHA
	TYA
	PHA

	;--- 1. Copy RL_STUB_IMAGE to $033C ---
	; Image includes stub code + padding + NMI redirect + metadata cells.
	; Total = $0370 - $033C = 52 bytes — single Y loop is sufficient.
	LDY #0
rl_inst_stub_loop:
	LDA RL_STUB_IMAGE, Y
	STA RL_STUB, Y
	INY
	CPY #RL_STUB_IMAGE_SIZE
	BNE rl_inst_stub_loop

	;--- 2. Copy RL_HANDLER_IMAGE to $E800 (multi-page) ---
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
	BEQ rl_inst_nmi

	LDY #0
rl_inst_partial_loop:
	LDA ($8B), Y
	STA ($8D), Y
	INY
	DEX
	BNE rl_inst_partial_loop

rl_inst_nmi:
	;--- 3. Write RL_NMI_REDIRECT address to $FFFA/$FFFB ---
	; Writes always go to RAM (6502 write behaviour, $01-independent).
	; Under $01=$35 (HIRAM=0): reads from $FFFA/$FFFB also see RAM.
	; Under $01=$37 (HIRAM=1): reads see Kernal ROM ($FE43) → JMP ($0318).
	; Both are fine — belt-and-suspenders safety.
	LDA #<RL_NMI_REDIRECT       ; = $68
	STA $FFFA
	LDA #>RL_NMI_REDIRECT       ; = $03
	STA $FFFB

	;--- 4. Backup original $0330/$0331 ---
	LDA $0330
	STA RL_ORIG_VEC             ; = $036B (already copied to RAM in step 1)
	LDA $0331
	STA RL_ORIG_VEC + 1

	;--- 5. Patch $0330/$0331 to point to RL_STUB ---
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

RL_UNINSTALL:
	PHA
	LDA RL_ORIG_VEC
	STA $0330
	LDA RL_ORIG_VEC + 1
	STA $0331
	PLA
	RTS
