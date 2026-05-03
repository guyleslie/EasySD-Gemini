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
;   2. RL_NMI_REDIRECT at $0370: JMP ($0318) written to $FFFA/$FFFB by
;      RL_INSTALL so NMI dispatch works correctly under $01=$35.
;   3. SA=0 support: handler checks $B9 and uses RL_SAVED_X/Y as load target.
;   4. Embedded RL_MINI_CARTLIB at $EA00 — NO #SETBANK anywhere.
;      Games loading to $C000+ no longer break the hook.
;   5. chdir safety: rl_chdir_to_game sends COMMAND_GOTO_PATH before each LOAD.
;
; V2.1 FIX:
;   6. Early stub passthrough: device != 8 check moved from handler ($E800)
;      to stub ($033C), BEFORE $01 banking switch.  Non-device-8 LOADs now
;      pass through with original $01, registers, and stack intact.
;
; COMPONENTS:
;   A) RL_STUB_IMAGE — trampoline copied to $033C (up to 44 bytes).
;      Patches $0330/$0331 so every JSR $FFD5 arrives here.
;      Early device check: non-8 LOADs pass through immediately (no banking change).
;      Device 8: saves X, Y, $01; switches to $35; calls handler; restores all.
;   B) RL_HANDLER_IMAGE — handler+mini-CartLib copied to $E800-$EBFF.
;      Runs entirely with $01=$35 (Kernal RAM visible, ROML accessible).
;      Calls only RL_MINI_CARTLIB routines (at $EA00+) — never $C000+ CartLib.
;   C) RL_INSTALL — run once by BOOT.PRG to copy images and install hooks.
;
; MEMORY LAYOUT (constants in Common/System.inc):
;   $0330/$0331   Kernal LOAD vector       → patched to $033C (RL_STUB)
;   $033C-$036F   RL_STUB code + padding to RL_NMI_REDIRECT
;   $0370-$0372   RL_NMI_REDIRECT: JMP ($0318) — written to $FFFA/$FFFB
;   $0373-$0374   RL_ORIG_VEC (2 bytes)     backup of original $0330/$0331
;   $0375         RL_SAVED_01 (1 byte)      game's $01 during hook
;   $0376         RL_SAVED_X  (1 byte)      game's X at LOAD call (SA=0)
;   $0377         RL_SAVED_Y  (1 byte)      game's Y at LOAD call (SA=0)
;   $0378+        RL receive/launch stubs    low-RAM wait loop + first launch tail
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
; Early device check: if device ($BA) != 8, passes through to original
; Kernal LOAD immediately — no banking change, no register modification.
; Device 8: saves X, Y, $01; switches to $35; calls RL_HANDLER; restores all.
;================================================================================

RL_STUB_IMAGE:
.logical $033C

RL_STUB_ENTRY:
	;--- Early passthrough: device != 8 goes to original Kernal LOAD immediately ---
	; No banking switch, no register modification — original environment preserved.
	PHA                         ; save A (secondary address from Kernal call)
	LDA KERNAL_DEVICE_NUMBER    ; $BA — current device number
	CMP #8
	BEQ rl_stub_dev8
	PLA                         ; restore A — original X/Y/$01/stack intact
	JMP (RL_ORIG_VEC)           ; forward to original Kernal LOAD

rl_stub_dev8:
	;--- Device 8: enter resident loader ---

	PHP                         ; preserve caller IRQ/status; return C is restored below
	SEI                         ; no IRQ while $01=$35 exposes RAM vectors
	STX RL_SAVED_X              ; save X (= MEMUSS lo if SA=0)
	STY RL_SAVED_Y              ; save Y (= MEMUSS hi if SA=0)
	LDA PROCESSOR_PORT
	STA RL_SAVED_01
	LDA #PP_CONFIG_RAM_ON_ROM   ; $35: Kernal RAM visible, ROML accessible
	STA PROCESSOR_PORT
	JSR RL_HANDLER              ; → $E800; returns C=0/1, X=end_lo, Y=end_hi
	PHP                         ; keep handler carry while restoring banking/status
	LDA RL_SAVED_01
	STA PROCESSOR_PORT          ; restore game's banking while IRQs are still masked
	PLP                         ; restore handler carry for the branch below
	BCS rl_stub_return_error
	PLP                         ; restore caller IRQ/status
	PLA                         ; restore A
	CLC                         ; success from RL_HANDLER
	RTS                         ; X/Y = end address from RL_HANDLER
rl_stub_return_error:
	PLP                         ; restore caller IRQ/status
	PLA                         ; restore A
	SEC                         ; error from RL_HANDLER
	RTS                         ; X/Y = end address from RL_HANDLER

; Ensure stub code ends before RL_NMI_REDIRECT ($0370)
; Stub now uses $033C-$036F range.
.if * > RL_NMI_REDIRECT
	.error "RL_STUB code exceeds RL_NMI_REDIRECT — reduce stub size"
.endif

; --- padding to RL_NMI_REDIRECT ---
.fill RL_NMI_REDIRECT - *, $00

; --- RL_NMI_REDIRECT ---
; JMP ($0318): on NMI with $01=$35, CPU reads $FFFA/$FFFB from RAM (written
; by RL_INSTALL), arrives here, then dispatches via SOFTNMIVECTOR → $80AF.
; Label NOT redefined here — RL_NMI_REDIRECT lives in System.inc.
.fill RL_NMI_REDIRECT - *, $00
	JMP ($0318)                 ; 3 bytes: $6C $18 $03

; --- metadata cells after RL_NMI_REDIRECT ---
; Labels NOT redefined here — RL_ORIG_VEC/$SAVED_01/X/Y live in System.inc.
; These bytes are initialised on copy; RL_INSTALL / RL_STUB overwrite at runtime.
	.byte $00, $00             ; RL_ORIG_VEC placeholder
	.byte $37                  ; RL_SAVED_01 placeholder (default $01=$37)
	.byte $00                  ; RL_SAVED_X placeholder
	.byte $00                  ; RL_SAVED_Y placeholder

; --- low-RAM wait/launch stubs after metadata ---
; These routines are visible in every banking mode.  The resident handler runs
; under $01=$35 at $E800, but the proven NMI receive path waits under $01=$37,
; and first-part launch must not return to MLBoot's overwriteable $C000 code.
RL_RECEIVE_WAIT_STUB:
	LDA #$FF
	STA RL_WAIT_TIMEOUT_LO
	STA RL_WAIT_TIMEOUT_MID
	LDA #$08
	STA RL_WAIT_TIMEOUT_HI
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT
	LDX ZP_IRQ_API_DATA_LENGTH
	LDY #$00
	CLV
-
	BIT ZP_IRQ_STATE_WAITHANDLE
	BVS rl_wait_done
	DEC RL_WAIT_TIMEOUT_LO
	BNE -
	DEC RL_WAIT_TIMEOUT_MID
	BNE -
	DEC RL_WAIT_TIMEOUT_HI
	BNE -
	LDA #$02
	STA BORDER
	LDA #PP_CONFIG_RAM_ON_ROM
	STA PROCESSOR_PORT
	SEC
	RTS
rl_wait_done:
	LDA #PP_CONFIG_RAM_ON_ROM
	STA PROCESSOR_PORT
	CLC
	RTS

RL_WAIT_TIMEOUT_LO:
	.byte $00
RL_WAIT_TIMEOUT_MID:
	.byte $00
RL_WAIT_TIMEOUT_HI:
	.byte $00

; Called by MLBoot after RL_INSTALL and filename setup.  The JSR $FFD5 must
; live in low RAM: large first-part PRGs can overwrite the $C000 MLBoot blob
; before Kernal LOAD returns.
RL_BOOT_LOAD_STUB:
	LDA #$00
	JSR $FFD5
	PHP
	LDA #PP_CONFIG_RAM_ON_ROM
	STA PROCESSOR_PORT
	PLP
	JMP RL_LAUNCH_AFTER_LOAD

RL_BASIC_RUN_STUB:
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT
	JSR $A659
	JMP $A7AE

RL_MACHINE_JUMP_STUB:
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT
	JMP ($008B)

RL_RESET_ERROR_STUB:
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT
	JMP RESETROUTINE

RL_STAGE_BORDER:
	STA BORDER
	RTS

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
	; Device check already done by RL_STUB — only device 8 reaches here.
	LDA VIC_CONTROL_1
	STA rl_saved_d011
	AND #$EF                    ; display off during bus-sensitive transfer
	STA VIC_CONTROL_1
	LDA VIC_INT_CONTROL
	STA rl_saved_d01a
	ASL VIC_INT_ACK             ; ack pending VIC IRQ flags
	LDA #$00
	STA VIC_INT_CONTROL         ; disable VIC IRQ sources, restore on exit
	JMP rl_main

;----------------------------------------------
; Data areas — fixed addresses within handler image.
; Uses .fill padding to reach exact RL_* constants from System.inc.
;----------------------------------------------

; Saved game NMI vector ($0318/$0319) — restored after each transfer
rl_saved_d011: .byte 0
rl_saved_d01a: .byte 0
rl_saved_nmi_lo: .byte 0
rl_saved_nmi_hi: .byte 0

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
	LDA #$06
	JSR RL_STAGE_BORDER
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
	LDA #$04
	JSR RL_STAGE_BORDER
	LDX #$01
	JSR RL_OpenFile
	BCC rl_opened_ok
	JMP rl_error_talking        ; open failed, EndTalking still needed
rl_opened_ok:
	LDA #$05
	JSR RL_STAGE_BORDER
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
	LDA #$07
	JSR RL_STAGE_BORDER
	JSR RL_ReadFileNoCallback
	BCC rl_hdr_ok
	JMP rl_error_opened
rl_hdr_ok:
	LDA #$0D
	JSR RL_STAGE_BORDER
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

	LDA #$0E
	JSR RL_STAGE_BORDER
	JSR RL_LoadFileBySize
	BCC rl_after_load
	JMP rl_error_opened

rl_after_load:
	LDA #$03
	JSR RL_STAGE_BORDER
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
	JSR rl_restore_vic_state
	CLC                         ; success: C=0, X=end_lo, Y=end_hi
	RTS

;--- Error handlers ---
rl_error_opened:
	JSR RL_CloseFile
rl_error_talking:
	JSR RL_EndTalking           ; NO #SETBANK
rl_error_pre_talking:
	JSR rl_restore_vic_state
	SEC
	RTS

rl_restore_vic_state:
	LDA rl_saved_d011
	STA VIC_CONTROL_1
	LDA rl_saved_d01a
	STA VIC_INT_CONTROL
	RTS

;----------------------------------------------
; RL_LAUNCH_AFTER_LOAD
; Entered from RL_BOOT_LOAD_STUB in low RAM after the first-part Kernal LOAD.
; The stub switches to $01=$35 before jumping here, so this code is safe under
; Kernal RAM even when the loaded PRG overwrote MLBoot's $C000 blob.
;----------------------------------------------
RL_LAUNCH_AFTER_LOAD:
	BCC rl_launch_load_ok
	JMP rl_launch_load_error

rl_launch_load_ok:
	LDA #$0A
	JSR RL_STAGE_BORDER
	STX $8D                         ; end_lo  (post-LOAD: byte after last)
	STY $8E                         ; end_hi

	LDA rl_hdr_area                 ; first PRG header byte, already in $E8C4 RAM
	STA $8B                         ; load_lo
	LDA rl_hdr_area + 1
	STA $8C                         ; load_hi

	; Program system pointers so BASIC/CLR does not overwrite the loaded PRG.
	LDA $8D
	STA $2D
	STA $2F
	STA $AE                         ; LOAD_START_LO
	LDA $8E
	STA $2E
	STA $30
	STA $AF                         ; LOAD_START_HI

	; Start the game with the same clean vector/device state as normal PRG load.
	LDA #$47
	STA SOFTNMIVECTOR
	LDA #$FE
	STA SOFTNMIVECTOR + 1
	LDA #$31
	STA IRQVECTOR
	LDA #$EA
	STA IRQVECTOR + 1
	LDA #$1B
	STA VIC_CONTROL_1
	LDA #$08
	STA KERNAL_DEVICE_NUMBER
	LDA #$81
	STA CIA_1_BASE + CIA_INT_MASK

	JSR RL_ShouldRunBasic
	BCS rl_launch_machine

	LDA #$00
	STA BORDER
	JMP RL_BASIC_RUN_STUB

rl_launch_machine:
	LDA #$00
	STA BORDER
	JMP RL_MACHINE_JUMP_STUB

rl_launch_load_error:
	LDA #$02
	STA BORDER
	LDA #$00
	STA SCREEN
	LDX #200
rl_launch_err_outer:
	LDY #0
rl_launch_err_inner:
	DEY
	BNE rl_launch_err_inner
	DEX
	BNE rl_launch_err_outer
	JMP RL_RESET_ERROR_STUB

; Decide whether the loaded first-part PRG should be launched through BASIC.
; C=0 => BASIC RUN, C=1 => machine launch via $8B/$8C.
RL_ShouldRunBasic:
	LDA $8C
	CMP #$08
	BNE rl_chk_hybrid
	LDA $8B
	CMP #$01
	BEQ rl_chk_0801
	JMP rl_machine_decision

rl_chk_0801:
	LDA $0805
	BEQ rl_dummy_0801
	CLC
	RTS

rl_dummy_0801:
	JSR RL_ParseHiddenSys
	SEC
	RTS

rl_chk_hybrid:
	BCS rl_machine_decision          ; load address > $08xx -> not BASIC
	LDA $8E
	CMP #$08
	BCC rl_machine_decision
	BNE rl_chk_sys_token
	LDA $8D
	CMP #$09
	BCC rl_machine_decision
rl_chk_sys_token:
	LDA $0805
	CMP #$9E
	BNE rl_machine_decision
	CLC
	RTS

rl_machine_decision:
	SEC
	RTS

; Dummy $0801 loaders often hide a tokenized SYS line after an empty first
; BASIC line.  Last Ninja+ uses this pattern: $0805=$00, then token $9E and
; decimal entry address later in the same first page.
RL_ParseHiddenSys:
	LDA #$12
	STA $8B
	LDA #$08
	STA $8C
	LDY #$06
rl_find_hidden_sys:
	CPY #$20
	BCS rl_parse_sys_done
	LDA $0800, Y
	CMP #$9E
	BEQ rl_parse_sys_digits
	INY
	BNE rl_find_hidden_sys

rl_parse_sys_digits:
	INY
	LDA #$00
	STA $8B
	STA $8C
rl_parse_digit_loop:
	LDA $0800, Y
	CMP #'0'
	BCC rl_parse_digit_done
	CMP #$3A
	BCS rl_parse_digit_done
	SEC
	SBC #'0'
	STA ZP_IRQ_TMP_SCRATCH

	LDA $8B
	STA $8D
	LDA $8C
	STA $8E
	ASL $8D
	ROL $8E                         ; temp = old * 2
	LDA $8D
	STA $8B
	LDA $8E
	STA $8C
	ASL $8B
	ROL $8C
	ASL $8B
	ROL $8C                         ; acc = old * 8
	CLC
	LDA $8B
	ADC $8D
	STA $8B
	LDA $8C
	ADC $8E
	STA $8C                         ; acc = old * 10
	CLC
	LDA $8B
	ADC ZP_IRQ_TMP_SCRATCH
	STA $8B
	BCC rl_parse_no_carry
	INC $8C
rl_parse_no_carry:
	INY
	BNE rl_parse_digit_loop

rl_parse_digit_done:
	LDA $8B
	ORA $8C
	BNE rl_parse_sys_done
	LDA #$12
	STA $8B
	LDA #$08
	STA $8C
rl_parse_sys_done:
	RTS

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

;--- Interrupt disable helper ---
; Only disables CIA2 NMI sources to prevent spurious NMIs during transfer.
; CIA1 and VIC interrupt sources are left intact — SEI masks IRQs sufficiently.
; NOTE: CIA2 ICR mask cannot be read back (6526 hardware limitation), so the
; original enable state is lost. This is an acceptable compromise because
; virtually no multiload games use CIA2 NMI sources.
RL_DisableInterrupts:
	LDA #$7F
	STA CIA_2_BASE + CIA_INT_MASK   ; disable all CIA2 NMI sources
	LDA CIA_2_BASE + CIA_INT_MASK   ; ack pending
	RTS

;--- RL_ReceiveFragmentNoCallback ---
; The setup runs in RL_HANDLER under $01=$35, but the actual NMI receive wait
; is delegated to RL_RECEIVE_WAIT_STUB in low RAM. That stub switches to
; $01=$37 while waiting so the NMI path uses the same Kernal trampoline and
; timing as the stable CartLib PROT_ReceiveFragmentNoCallback path.
;
; Setup: ZP_IRQ_API_DATA_LO/HI = target; ZP_IRQ_API_DATA_LENGTH = page count.
; Y in: transfer mode (0=x1, 1=x4, 2=x8).
RL_ReceiveFragmentNoCallback:
	; Save game's NMI vector before overwriting
	LDA SOFTNMIVECTOR           ; $0318
	STA rl_saved_nmi_lo
	LDA SOFTNMIVECTOR + 1       ; $0319
	STA rl_saved_nmi_hi

	JSR RL_DisableInterrupts    ; CIA2 NMI sources only
	LDA RL_NMITAB, Y
	STA SOFTNMIVECTOR
	LDA #$80                    ; high byte of $8000 (ROML — TransferHandler)
	STA SOFTNMIVECTOR + 1

	LDA #$00
	STA ZP_IRQ_STATE_WAITHANDLE

	JSR RL_RECEIVE_WAIT_STUB
	PHP

	; Restore game's NMI vector
	LDA rl_saved_nmi_lo
	STA SOFTNMIVECTOR
	LDA rl_saved_nmi_hi
	STA SOFTNMIVECTOR + 1

	PLP
	BCS rl_receive_timeout
	LDA #0
	CLC
	RTS

rl_receive_timeout:
	LDA #0
	SEC
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
; Interrupts remain disabled (SEI from RL_StartTalking). RL_STUB will CLI
; after restoring $01, so game IRQ handlers never run under wrong banking.
RL_EndTalking:
	LDA #COMMAND_END_TALKING
	JSR RL_Send
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
;   3. Write RL_NMI_REDIRECT address to $FFFA/$FFFB (RAM NMI vector).
;   4. Backup original $0330/$0331 → RL_ORIG_VEC.
;   5. Patch $0330/$0331 → RL_STUB ($033C).
;
; RL_UNINSTALL (call on error exit, before returning to menu):
;   Restores $0330/$0331 from RL_ORIG_VEC.
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
	; Image includes stub code + padding + NMI redirect + metadata cells
	; and the low-RAM receive wait stub. Single Y loop is sufficient.
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
	LDA #<RL_NMI_REDIRECT
	STA $FFFA
	LDA #>RL_NMI_REDIRECT
	STA $FFFB

	;--- 4. Backup original $0330/$0331 ---
	LDA $0330
	STA RL_ORIG_VEC             ; already copied to RAM in step 1
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
