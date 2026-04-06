;================================================================================
; MultiLoad.s — EASYLOAD.PRG: Multi-Load Game Launcher Plugin
;================================================================================
;
; PURPOSE:
;   Plugin selected by the user from the EasySD menu when the user has
;   navigated to a game directory containing multi-load game files.
;   Installs a resident LOAD hook, loads the first game part, and jumps to it.
;   The game then runs normally; subsequent LOAD "FILE",8,x calls are
;   intercepted by the resident hook and served from the SD card.
;
; SD CARD LAYOUT (/MULTILOAD/GAMENAME/):
;   EASYLOAD.PRG    ← this plugin, patched by create_multiload.py
;   GAMENAME.PRG    ← first game part (ML_FIRST_PART_NAME + ".PRG")
;   LEVEL1.PRG      ← loaded by game via LOAD "LEVEL1",8,1
;   LEVEL2.PRG      ← etc.
;
; USAGE:
;   1. python Tools/build.py multiload
;   2. python Tools/create_multiload.py --from-disk GAME.d64
;   3. Extract ZIP to SD card root
;   4. Navigate to /MULTILOAD/GAMENAME/ in EasySD menu, select EASYLOAD.PRG
;
; ENTRY POINT:  $C000
; EXIT:         JMP to game (success) or PROT_ExitToMenu (error)
;
; PROTOCOL INVARIANT:
;   ALL exit paths must call PROT_EndTalking before returning to menu.
;
; KNOWN LIMITATIONS:
;   - LOAD calls that bypass $0330 via direct JSR $E16F cannot be intercepted.
;   - Game parts loading to $033C-$036F will overwrite the resident stub.
;   - LOAD with device != 8 is passed through to the original Kernal vector.
;
; DEPENDENCIES:
;   ResidentLoader.s, CartLibStream.s (included at bottom)
;================================================================================

; DEBUG mode - passed from command line (-D DEBUG=0 / -D DEBUG=1)
.include "../../DebugMacros.s"
.include "../../APIMacros.s"

; Hardware border-color debug markers — passed via -D ML_DEBUG_BORDERS=0/1.
; 0 = no markers (default, always passed by build.py).
; 1 = border colors at each stage, for real-hardware hang diagnosis.

;================================================================================
; Plugin entry — $C000
; Layout: JMP MAIN (3 bytes) then config block at $C003.
;================================================================================

	*=$C000
	JMP MAIN

;================================================================================
; Config block — $C003 to $C014
; Patched by Tools/create_multiload.py for each game.
; RL_ constants reference $C015+ (MAIN etc.) which follows this block.
;================================================================================

ML_CONFIG_VERSION:  .byte 3         ; $C003 — version sentinel, must be 3
ML_FIRST_PART_LEN:  .byte 0         ; $C004 — length of first-part filename incl. ".PRG" (patched)
ML_FIRST_PART_NAME: .fill 16, 0     ; $C005-$C014 — filename with ".PRG", null-padded (patched)

;================================================================================
; MAIN — entry point ($C015)
;================================================================================

MAIN:
	; --- Border color debug markers (compiled in with -D ML_DEBUG_BORDERS=1) ---
	; Color map: 1=white(entry) 2=red(savestate) 3=cyan(install) 4=purple(talking)
	;            5=green(sent) 6=blue(wait ok) 7=yellow(received) 8=orange(open ok)
	;            9=brown (open error)
	.if ML_DEBUG_BORDERS
	LDA #1
	STA $D020                       ; WHITE: MAIN entered
	.endif
	JSR ML_SAVESTATE                ; save VIC/$01 for error-path restore
	.if ML_DEBUG_BORDERS
	LDA #2
	STA $D020                       ; RED: ML_SAVESTATE done
	.endif

	; Install resident LOAD hook:
	;   copies RL_STUB image  → $033C (extended: saves X/Y, NMI redirect)
	;   copies RL_HANDLER+RL_MINI_CARTLIB → $E800-$EBFF
	;   writes RL_NMI_REDIRECT address ($0368) to $FFFA/$FFFB (RAM NMI vector)
	;   patches $0330/$0331 → RL_STUB ($033C)
	JSR RL_INSTALL
	.if ML_DEBUG_BORDERS
	LDA #3
	STA $D020                       ; CYAN: RL_INSTALL done
	.endif

	; Start EasySD session
	; Arduino is in the game directory (user navigated there before selecting
	; EASYLOAD.PRG).  We immediately capture the path for chdir safety.
	JSR PROT_StartTalking
	.if ML_DEBUG_BORDERS
	LDA #4
	STA $D020                       ; PURPLE: PROT_StartTalking done
	.endif

	;--- Capture current directory path into RL_DIR_PATH ($E840) ---
	; COMMAND_GET_PATH: Arduino sends dirFunc.currentPath (64 bytes) then
	; 192 zero bytes = 1 NMI page total.  We receive it at $E840.
	; Writes always reach RAM regardless of $01, so $E840 gets populated
	; even though $01=$37 (Kernal ROM is mapped there for reads).
	; This path is later read by RL_HANDLER under $01=$35 (Kernal RAM).
	LDA #COMMAND_GET_PATH
	JSR PROT_Send
	.if ML_DEBUG_BORDERS
	LDA #5
	STA $D020                       ; GREEN: PROT_Send done, about to WaitProcessing
	.endif
	JSR PROT_WaitProcessing
	BCS ml_skip_path                ; skip on error — graceful degradation
	.if ML_DEBUG_BORDERS
	LDA #6
	STA $D020                       ; BLUE: PROT_WaitProcessing returned CLC (success)
	.endif

	LDA #<RL_DIR_PATH               ; = $40 (low byte of $E840)
	STA ZP_IRQ_API_DATA_LO
	LDA #>RL_DIR_PATH               ; = $E8 (high byte of $E840)
	STA ZP_IRQ_API_DATA_HI
	LDA #1
	STA ZP_IRQ_API_DATA_LENGTH      ; 1 page = 256 bytes
	LDY #$00                        ; transfer mode x1 (CARTRIDGENMIHANDLERX1)
	JSR PROT_ReceiveFragmentNoCallback
	.if ML_DEBUG_BORDERS
	LDA #7
	STA $D020                       ; YELLOW: path received, about to open first part
	.endif

ml_skip_path:
	;--- Open first game part ---
	; ML_FIRST_PART_NAME contains the full filename including ".PRG"
	; (e.g. "LAST NINJA 2.PRG"), patched by create_multiload.py.
	LDA ML_FIRST_PART_LEN
	LDX #<ML_FIRST_PART_NAME
	LDY #>ML_FIRST_PART_NAME
	JSR PROT_SetName
	LDX #$01                        ; flags = read
	JSR PROT_OpenFile
	BCC ml_opened
	.if ML_DEBUG_BORDERS
	LDA #9
	STA $D020                       ; BROWN: PROT_OpenFile failed
	.endif
	JMP MAIN_ERROR

ml_opened:
	.if ML_DEBUG_BORDERS
	LDA #8
	STA $D020                       ; ORANGE: PROT_OpenFile success
	.endif
	; Get file info (size)
	#GETFILEINFO ML_FILEINFO_BUF
	BCS MAIN_ERROR

	; Store 32-bit file size
	LDA ML_FILEINFO_BUF + 28
	STA ZP_LOADFILE_API_SIZE0
	LDA ML_FILEINFO_BUF + 29
	STA ZP_LOADFILE_API_SIZE1
	LDA ML_FILEINFO_BUF + 30
	STA ZP_LOADFILE_API_SIZE2
	LDA ML_FILEINFO_BUF + 31
	STA ZP_LOADFILE_API_SIZE3

	; Read first page to ML_HDRBUF: 2-byte PRG header + up to 254 data bytes
	LDA #<ML_HDRBUF
	STA ZP_IRQ_API_DATA_LO
	LDA #>ML_HDRBUF
	STA ZP_IRQ_API_DATA_HI
	LDA #1
	STA ZP_IRQ_API_DATA_LENGTH
	LDY #$00
	JSR PROT_ReadFileNoCallback
	BCS MAIN_ERROR

	; ML_HDRBUF[0..1] = PRG load address (little-endian)
	; ML_HDRBUF[2..255] = first 254 bytes of program data

	LDA ML_HDRBUF
	STA $8B                         ; load address lo
	LDA ML_HDRBUF + 1
	STA $8C                         ; load address hi

	; Branch on file size
	LDA ZP_LOADFILE_API_SIZE1
	BNE ml_big_first

	; Small first part (size <= 255 bytes): copy (SIZE-2) data bytes only
	SEC
	LDA ZP_LOADFILE_API_SIZE0
	SBC #2
	BCC ml_close                    ; SIZE < 2 (header only)
	BEQ ml_close                    ; SIZE = 2 (header only, no data)
	TAX
	LDY #0
ml_copy_small:
	LDA ML_HDRBUF + 2, Y
	STA ($8B), Y
	INY
	DEX
	BNE ml_copy_small
	JMP ml_close

ml_big_first:
	; Large first part: copy first 254 data bytes, load rest via LoadFileBySize
	LDY #0
ml_copy_254:
	LDA ML_HDRBUF + 2, Y
	STA ($8B), Y
	INY
	CPY #254
	BNE ml_copy_254

	; Setup LoadFileBySize: target = load_addr+254, skip = 256 (already read)
	CLC
	LDA ML_HDRBUF
	ADC #254
	STA ZP_IRQ_API_DATA_LO
	LDA ML_HDRBUF + 1
	ADC #0
	STA ZP_IRQ_API_DATA_HI

	LDA #$00
	STA ZP_LOADFILE_API_SKIP_LO     ; skip = $0100 = 256
	LDA #$01
	STA ZP_LOADFILE_API_SKIP_HI

	JSR LoadFileBySize
	BCS MAIN_ERROR

ml_close:
	JSR PROT_CloseFile
	JSR PROT_EndTalking

	; Refresh load address pointer ($8B/$8C may be stale after copy loops)
	LDA ML_HDRBUF
	STA $8B
	LDA ML_HDRBUF + 1
	STA $8C

	; Jump to game — resident hook handles all future LOAD "...",8,x calls
	JMP ($008B)

;================================================================================
; Error path: end EasySD session, restore state, return to menu
;================================================================================

MAIN_ERROR:
	JSR PROT_EndTalking
ML_EXIT_TO_MENU:
	JSR RL_UNINSTALL                ; restore $0330/$0331 — see ResidentLoader.s
	JSR ML_RESTORESTATE
	JSR PROT_ExitToMenu
	JMP *                           ; unreachable

;================================================================================
; ML_SAVESTATE / ML_RESTORESTATE — minimal VIC/$01 save for error path
;================================================================================

ML_SAVED_01:   .byte $37
ML_SAVED_D011: .byte $3B

ML_SAVESTATE:
	LDA PROCESSOR_PORT
	STA ML_SAVED_01
	LDA VIC_CONTROL_1
	STA ML_SAVED_D011
	RTS

ML_RESTORESTATE:
	LDA #$37                        ; ensure I/O visible before accessing $D011
	STA PROCESSOR_PORT
	LDA ML_SAVED_D011
	STA VIC_CONTROL_1
	LDA ML_SAVED_01
	STA PROCESSOR_PORT
	RTS

;================================================================================
; Data areas (in $C000 plugin space — always-accessible RAM)
;================================================================================

ML_FILEINFO_BUF: .fill 32          ; FAT directory entry (32 bytes)
ML_HDRBUF:       .fill 256         ; first-page read buffer (PRG header + data)

;================================================================================
; ResidentLoader code (stub image, handler image + mini-CartLib, RL_INSTALL)
; Included here so it is part of the plugin binary.
; Must come BEFORE CartLibStream.s so forward references in handler image work.
;================================================================================
.include "../../ResidentLoader.s"

;================================================================================
; CartLib (full chain: CartLibStream → CartLibHi → CartLib → CartLibCommon)
; Included AFTER ResidentLoader so all forward references resolve correctly.
;================================================================================
.include "../../CartLibStream.s"

;================================================================================
; Overflow guard — plugin must not reach I/O space
;================================================================================
.if * > $DF00
	.error "MultiLoad plugin overflow: exceeds $DF00 (I/O space)"
.endif
