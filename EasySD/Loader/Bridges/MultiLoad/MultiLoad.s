;================================================================================
; MultiLoad.s — BOOT.PRG: Multi-Load Game Launcher Plugin
;================================================================================
;
; PURPOSE:
;   Plugin selected by the user from the EasySD menu when the user has
;   navigated to a game directory containing multi-load game files.
;   Installs a resident LOAD hook, loads the first game part, and jumps to it.
;   The game then runs normally; subsequent LOAD "FILE",8,x calls are
;   intercepted by the resident hook and served from the same SD directory.
;
; GAME-SPECIFIC CONFIGURATION:
;   Change FIRST_PART_NAME to the name of the first game part (without .PRG).
;   Rebuild with: python Tools/build.py multiload
;
; SD CARD LAYOUT EXPECTED:
;   /GAMES/MYGAME/
;     BOOT.PRG        ← this plugin (user selects this)
;     LOADER.PRG      ← FIRST_PART_NAME (e.g. "LOADER")
;     LEVEL1.PRG      ← LOAD "LEVEL1",8,1 from game code
;     LEVEL2.PRG      ← LOAD "LEVEL2",8,1 from game code
;
; ENTRY POINT:  $C000 (standard plugin load address)
; EXIT:         JMP to game entry point (never returns to menu unless error)
;
; PROTOCOL INVARIANT:
;   ALL EasySD sessions MUST be closed with IRQ_EndTalking on ALL exit paths.
;
; V1 LIMITATIONS:
;   - Only SA=1 (load to PRG header address) supported; SA=0 (MEMUSS) deferred to V2.
;   - CartLib functions at $C000 must not be overwritten by game parts.
;     Games that load a new engine to $C000 will break the hook.  Fix in V2.
;   - No chdir on each LOAD call; Arduino stays in game dir from user navigation.
;
; DEPENDENCIES:
;   ResidentLoader.s, CartLibStream.s (included at bottom)
;
; AUTHOR: Claude Sonnet 4.6 (Sprint 14)
; DATE: 2026-03-15
;================================================================================

; DEBUG mode - passed from command line (-D DEBUG=0 / -D DEBUG=1)
.include "../../DebugMacros.s"
.include "../../APIMacros.s"

;================================================================================
; GAME-SPECIFIC CONFIGURATION — adjust per game
;================================================================================
; Name of the first game part to load (plain filename, no .PRG extension).
; This name is loaded directly via the EasySD CartLib API (not via Kernal hook).
; The hook intercepts all *subsequent* LOAD "...",8 calls from the game itself.

FIRST_PART_NAME:
	.text "LOADER"                  ; ← CHANGE THIS per game
FIRST_PART_LEN = * - FIRST_PART_NAME

;================================================================================
; Plugin entry
;================================================================================

	*=$C000
	JMP MAIN

;================================================================================
; MAIN — entry point
;================================================================================

MAIN:
	JSR ML_SAVESTATE                ; save VIC/$01 for error-path restore

	; Install resident LOAD hook (copies stub to $033C, handler to $E800,
	; patches $0330/$0331).  Does NOT need an active EasySD session.
	JSR RL_INSTALL

	; Start EasySD session — Arduino is already in the game directory
	; (user navigated there before selecting BOOT.PRG).
	JSR IRQ_StartTalking

	; Open the first game part
	LDA #FIRST_PART_LEN
	LDX #<FIRST_PART_NAME
	LDY #>FIRST_PART_NAME
	JSR IRQ_SetName
	LDX #$01                        ; flags = read
	JSR IRQ_OpenFile
	BCC ml_opened
	JMP MAIN_ERROR

ml_opened:
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
	JSR IRQ_ReadFileNoCallback
	BCS MAIN_ERROR

	; ML_HDRBUF[0..1] = PRG load address (little-endian)
	; ML_HDRBUF[2..255] = first 254 bytes of program data

	; Store load address as ZP copy pointer and load target
	LDA ML_HDRBUF
	STA $8B                         ; ptr_lo for initial data copy
	LDA ML_HDRBUF + 1
	STA $8C                         ; ptr_hi

	; Branch on file size for correct handling
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
	; Large first part: copy first 254 data bytes, then load rest via LoadFileBySize
	LDY #0
ml_copy_254:
	LDA ML_HDRBUF + 2, Y
	STA ($8B), Y
	INY
	CPY #254
	BNE ml_copy_254

	; Setup LoadFileBySize: target = load_addr+254, skip = 256
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
	JSR IRQ_CloseFile
	JSR IRQ_EndTalking

	; Refresh load address pointer ($8B/$8C may be stale after copy loops)
	LDA ML_HDRBUF
	STA $8B
	LDA ML_HDRBUF + 1
	STA $8C

	; Jump to game — does not return to menu (resident hook handles future LOADs)
	JMP ($008B)

;================================================================================
; Error path: end EasySD session, restore state, return to menu
;================================================================================

MAIN_ERROR:
	JSR IRQ_EndTalking
ML_EXIT_TO_MENU:
	JSR ML_RESTORESTATE
	JSR IRQ_ExitToMenu
	JMP *                           ; unreachable

;================================================================================
; ML_SAVESTATE / ML_RESTORESTATE — minimal VIC/$01 save for error path
;================================================================================

ML_SAVED_01:   .byte $37
ML_SAVED_D011: .byte $3B

ML_SAVESTATE:
	LDA PROCESSOR_PORT
	STA ML_SAVED_01
	LDA $D011
	STA ML_SAVED_D011
	RTS

ML_RESTORESTATE:
	LDA #$37                        ; ensure I/O visible before accessing $D011
	STA PROCESSOR_PORT
	LDA ML_SAVED_D011
	STA $D011
	LDA ML_SAVED_01
	STA PROCESSOR_PORT
	RTS

;================================================================================
; Data areas (in $C000 plugin space — always-accessible RAM)
;================================================================================

ML_FILEINFO_BUF: .fill 32          ; FAT directory entry (32 bytes)
ML_HDRBUF:       .fill 256         ; first-page read buffer (PRG header + data)

;================================================================================
; ResidentLoader code (stub image, handler image, RL_INSTALL)
; Included here so it's part of the plugin binary.
;================================================================================
.include "../../ResidentLoader.s"

;================================================================================
; CartLib (full chain via CartLibStream → CartLibHi → CartLib → CartLibCommon)
; Included AFTER ResidentLoader so forward references in handler image resolve.
;================================================================================
.include "../../CartLibStream.s"

;================================================================================
; Overflow guard — plugin must not reach I/O space
;================================================================================
.if * > $DF00
	.error "MultiLoad plugin overflow: exceeds $DF00 (I/O space)"
.endif
