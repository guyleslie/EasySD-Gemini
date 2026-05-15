; Plugin supporting menu program for IrqHack64
; 31/07/2018 - Istanbul

;.enc ascii
; How menu works
; Micro sends this menu when user presses the button on the cartridge.
; Different from previous version, this version uses cartridge api for the low level work.
; It will employ plugins to react to different type of programs. (Video playing, wav playing so on.)


; --- Menu Constants ---
COMMANDENTERMASK = $00
COMMANDNEXTPAGE  = $40
COMMANDPREVPAGE  = $41
PATH_MAX         = 96
PATHBUF_SIZE     = 160
DIRLOAD_PAGES    = 3
DIRLOAD_TOTAL_BYTES = DIRLOAD_PAGES * 256

; --- Menu Zero Page Variables (User range $FB-$FE) ---
NAMELOW          = $FB
NAMEHIGH         = $FC
COLLOW           = $FD
COLHIGH          = $FE

; --- Menu RAM Variables ---
PATHBUFFER       = $033C ; FILE_PATH_BUF area ($033C-$03FB, re-used as path buffer — not tape I/O)

; --- External Routine Aliases ---
SIDPLAY          = $E003 ; SIDLOAD + 3 (SIDLOAD is from System.inc)

;CURRENTDIRINDEX is a variable (see variables section)
;CURRENTDIRINDEXSHADOW is a variable (see variables section)

DELAYFRAMES	.macro
	LDX #\1
	JSR WAITFRAMES
	.endm

; ROM Timing Control Macros
; Enable cartridge ROM access before reading from cartridge
CART_ROM_ENABLE .macro
	LDA #$37		; BASIC+KERNAL+I/O+Cartridge enabled
	STA $01
	.endm

; Restore normal configuration after cartridge access
CART_ROM_RESTORE .macro
	LDA #$35		; BASIC+KERNAL+I/O enabled (standard)
	STA $01
	.endm




* = $0801
	.word (+), 2015
	.null $9E, "2062"
+	.word 0

	*=$080E
	LDX #$FB
	TXS
	JSR PREINIT

	JSR DISPLAYPETGRAPHICS
	DELAYFRAMES 75

	JSR PROT_DisableDisplay
	JSR LOAD_CUSTOM_CHARSET		; copy custom charset to $3800, then update $D018
	JSR DISPLAYSCREENGRAPHICS
	LDA #$80
	STA $028A		; RPTFLG: repeat only cursor/function keys (enables held UP/DOWN scrolling)
	JSR PROT_StartTalking
	LDA #<DIRLOAD
	STA ZP_IRQ_API_DATA_LO
	LDA #>DIRLOAD
	STA ZP_IRQ_API_DATA_HI
	LDA #DIRLOAD_PAGES	; page-based receive buffer size
	STA ZP_IRQ_API_DATA_LENGTH
	LDA #<(DIRREAD-1)
	STA ZP_IRQ_API_CALLBACK_LO
	LDA #>(DIRREAD-1)
	STA ZP_IRQ_API_CALLBACK_HI	

	TSX
	STX $C000
	
	LDY #$00		
	LDX #MAXDIRITEMS
	LDA CURPAGEINDEX
	
	JSR PROT_ReadDirectory
	BCC _dir_ok
	LDA #$02			; red
	LDX #<MSG_SD_READ_ERR
	LDY #>MSG_SD_READ_ERR
	JSR STATUS_LINE
_dir_ok

;Start of main loop
INPUT_GET
	LDA ISMUSICPLAYING	;Decide to play music or not (ISMUSICPLAYING is just a hardcoded constant)
	BEQ SKIPMUSIC
	LDA #$A1	

;Waits until a certain raster line is reached to call the sid's play routine	
WAITPLAYRASTER			
	CMP $D012
	BNE WAITPLAYRASTER
	STA BORDER
	JSR SIDPLAY
	LDX #$00
	LDY $D012
	INY
	INY
WAITPLAYRASTEREND	
	CPY $D012
	BNE WAITPLAYRASTEREND
	
	STX BORDER

SKIPMUSIC	
	JSR SCNKEY		; Call kernal's key scan routine
 	JSR GETIN		; Get the pressed key by the kernal routine
  	BEQ INPUT_GET		; If zero then no key is pressed so repeat
  	CMP #$2E		; IF it's a > character
  	BEQ NEXTPAGE		; Then continue to request next page from micro
  	CMP #$2C		; IF it's a < character
  	BEQ PREVPAGE 		; Then continue to request previous page from micro
	CMP #$1D		; IF it's cursor RIGHT
	BEQ NEXTPAGE		; Page forward
	CMP #$9D		; IF it's cursor LEFT
	BEQ PREVPAGE		; Page backward
  	CMP #$91		; IF it's cursor UP
  	BEQ UP			; Then continue iterate up in the menu
  	CMP #$11		; IF it's cursor DOWN
  	BEQ DOWN 		; Then continue iterate down in the menu
  	CMP #$0D		; IF it's ENTER character
  	BEQ ENTER		; Then launch the selected item
	JMP INPUT_GET		; If other key then leave control to the main loop
		  	
UP
	LDX #COMMANDENTERMASK
	STX COMMANDBYTE
	JSR GETCURRENTROW		; X = current row
	BNE UP_MOVE			; X > 0 → normal move
	; --- at top of page (X=0) ---
	LDA CURPAGEINDEX		; on first page?
	BEQ UP_STOP			; yes → stop
	; has previous page → clear arrow, set flag, load prev page
	JSR CLEARARROW			; clear row 0
	LDA #1
	STA CURSOR_GOTO_LAST		; signal NEWCONTENT: cursor to last item
	JMP EXECPREV
UP_STOP
	JMP INPUT_GET			; first page first item: stop
UP_MOVE
	JSR CLEARARROW
	DEX
	JSR SETCURRENTROWHEAD
	JSR SETARROW
	JSR SCROLL_DELAY
	JMP INPUT_GET

DOWN
	LDX #COMMANDENTERMASK
	STX COMMANDBYTE
	JSR GETCURRENTROW		; X = current row
	INX				; tentative next row
	CPX CURPAGEITEMS		; at end of page?
	BNE DOWN_MOVE			; no → normal move
	; --- at page boundary ---
	LDA CURPAGEINDEX
	CLC
	ADC #1
	CMP PAGECOUNT			; CURPAGEINDEX+1 >= PAGECOUNT?
	BCS DOWN_STOP			; yes → last page, stop
	; has next page → clear arrow and load next page (cursor to row 0)
	JSR GETCURRENTROW		; restore X = old row (CURRENTROW unchanged)
	JSR CLEARARROW
	JMP NEXTPAGE
DOWN_STOP
	JMP INPUT_GET			; last page last item: stop
DOWN_MOVE
	DEX				; restore old row for CLEARARROW
	JSR CLEARARROW
	INX				; new row
	JSR SETCURRENTROWHEAD
	JSR SETARROW
	JSR SCROLL_DELAY
	JMP INPUT_GET

; Below routine fills the COMMANDBYTE to the relevant action taken by the user.
; With the start of the ENTER control byte is sent to micro by modulating raster interrupts


NEXTPAGE
	LDX CURPAGEINDEX
	INX
	CPX PAGECOUNT
	BCC EXECNEXT	; BCC = unsigned less-than (6502 has no BLT)
	JMP INPUT_GET
EXECNEXT
	INC CURPAGEINDEX	
	LDX #COMMANDNEXTPAGE
	STX COMMANDBYTE
	JSR PROT_DisableDisplay
	JMP DOREADDIRECTORY
	
SPLAY 	
	LDX #$45
	STX COMMANDBYTE
	CLV
	BVC ENTER
	
PREVPAGE  	  	  	
  	LDX CURPAGEINDEX
  	BNE EXECPREV
  	JMP INPUT_GET 
EXECPREV
	DEC CURPAGEINDEX
	LDX #COMMANDPREVPAGE
	STX COMMANDBYTE	
	JSR PROT_DisableDisplay	
	JMP DOREADDIRECTORY
	
ENTER  	  

	JSR PROT_DisableDisplay
	;Decide if it's a file selection or special command (previous / next)
	LDA COMMANDBYTE
	AND #$40
	BNE SPECIALCMD
	JSR GETCURRENTROW
	JSR ISDIRECTORY	
	BNE NODIRECTORY	

	JSR ISPREVIOUSDIRECTORY
	BCS NOPREV
	JSR GOBACK
	; Reset page index after navigating to parent directory.
	LDA #0
	STA CURPAGEINDEX
	;JMP NEWCONTENT
	JMP DOREADDIRECTORY

NOPREV
	; Enter directory (Arduino updates currentPath authoritatively)
	JMP ENTERDIR

; ------------------------------------------------------------
; PROT_GetCurrentPath
;   No input. Sends COMMAND_GET_PATH to Arduino, receives 256
;   bytes into PLUGIN_HEADER (safe 256-byte scratch buffer),
;   then copies first 64 bytes into PATHBUFFER.
;   On return: PATHBUFFER[0..63] = null-terminated current path.
;   Carry: clear on success, set on error.
;   Modifies: A, X, Y, ZP_IRQ_API_DATA_LO/HI, ZP_IRQ_API_DATA_LENGTH
; Note: PLUGIN_HEADER is used as the receive buffer to avoid
;   overwriting screen RAM that would occur if receiving to PATHBUFFER.
; ------------------------------------------------------------
PROT_GetCurrentPath
	; Receive 256 bytes into PLUGIN_HEADER (safe scratch, not screen RAM)
	LDA #<PLUGIN_HEADER
	STA ZP_IRQ_API_DATA_LO
	LDA #>PLUGIN_HEADER
	STA ZP_IRQ_API_DATA_HI
	; Send command
	LDA #COMMAND_GET_PATH
	JSR PROT_Send
	JSR PROT_WaitProcessing
	BPL _gcp_error		; positive value = error code
	; Receive 1 page (256 bytes): path in [0..63], rest zeros
	LDA #$01
	STA ZP_IRQ_API_DATA_LENGTH
	LDY #$00
	JSR PROT_ReceiveFragmentNoCallback
	; Copy first 64 bytes from PLUGIN_HEADER to PATHBUFFER
	LDY #0
_gcp_copy
	LDA PLUGIN_HEADER, Y
	STA PATHBUFFER, Y
	INY
	CPY #64
	BNE _gcp_copy
	CLC
	RTS
_gcp_error
	SEC
	RTS

; ------------------------------------------------------------
; ExtractLastDirname
;   Input : PATHBUFFER contains null-terminated path (e.g. "/GAMES/ACTION")
;   Output: NAMELOW/NAMEHIGH point to last component ("ACTION\0")
;   Modifies: A, X, Y
;   Note: call only for non-root paths (where PATHBUFFER[1] != 0)
; ------------------------------------------------------------
ExtractLastDirname
	; Scan for last '/' in PATHBUFFER, save its position in X
	LDY #0
	LDX #0			; X = position of last slash found
_eld_scan
	LDA PATHBUFFER, Y
	BEQ _eld_done
	CMP #$2F		; '/'
	BNE _eld_next
	TYA
	TAX			; save slash position
_eld_next
	INY
	BNE _eld_scan		; safe since path < 255 chars
_eld_done
	; X = position of last '/', INX points past it (first char of last component)
	INX
	TXA
	CLC
	ADC #<PATHBUFFER
	STA NAMELOW
	LDA #>PATHBUFFER
	ADC #0
	STA NAMEHIGH
	RTS


ENTERDIR
	; Set filename from selected directory record and change directory by name.
	; This is the proven path used in the stable 5331f47 flow.
	LDX NAMELOW
	LDY NAMEHIGH
	JSR PROT_SetNameZ
	JSR PROT_ChangeDirectory
	BCS CHANGEDIRFAIL
	; Reset page index — new directory always starts at page 0.
	; Without this, a stale CURPAGEINDEX causes startingIndex > count on
	; the Arduino, producing a uint8_t underflow → C64 gets CURPAGEITEMS=245
	; → PRINTPAGE loops 245 times → stack corruption → grey screen.
	LDA #0
	STA CURPAGEINDEX
	DELAYFRAMES 2
	; Read directory
DOREADDIRECTORY	
	LDA #<DIRLOAD
	STA ZP_IRQ_API_DATA_LO
	LDA #>DIRLOAD
	STA ZP_IRQ_API_DATA_HI
	LDA #DIRLOAD_PAGES	; page-based receive buffer size
	STA ZP_IRQ_API_DATA_LENGTH
	LDY #$00
	LDX #21			;Max 21 directory items
	LDA CURPAGEINDEX
	JSR PROT_ReadDirectoryNC
	BCC _dirNC_ok
	LDA #$02			; red
	LDX #<MSG_SD_READ_ERR
	LDY #>MSG_SD_READ_ERR
	JSR STATUS_LINE
_dirNC_ok
	
	JMP NEWCONTENT
	
	
CHANGEDIRFAIL
	LDA #$02			; red
	LDX #<MSG_CD_ERROR
	LDY #>MSG_CD_ERROR
	JSR STATUS_LINE
	JSR PROT_EnableDisplay
	JMP INPUT_GET
NODIRECTORY	
	;JMP INVOKEPETG
	JSR GETCURRENTROW				; We have current row in X
	
	LDA NAMESLO, X
	STA NAMELOW
	LDA NAMESHI, X
	STA NAMEHIGH
	LDY #31
	LDA (NAMELOW), Y
	CMP #ENTRY_TYPE_PRG
	BEQ PROGRAM
	CMP #ENTRY_TYPE_CRT
	BEQ PROGRAM
	CMP #ENTRY_TYPE_KOA
	BEQ META_KOA
	CMP #ENTRY_TYPE_WAV
	BEQ META_WAV
	CMP #ENTRY_TYPE_CVD
	BEQ META_CVD

	JMP UNKNOWNFILE
META_KOA
	JSR SETEXT_KOA
	JMP PLUGIN
META_WAV
	JSR SETEXT_WAV
	JMP PLUGIN
META_CVD
	JSR SETEXT_CVD
	JMP PLUGIN
PLUGIN	
	JSR ISKOA
	BCS PLUGIN_PRG_PATH

	; KOA: use INVOKE_WITH_INDEX — Arduino detects .koa and handles the two-file
	; transfer (media + KOAPLUGIN.PRG) without a path round-trip to the Arduino.
	LDA CURPAGEINDEX
	JSR GETCURRENTROW
	LDY #$00		; flags = 0
	JSR PROT_InvokeWithIndex
	BCC KOAPLUGINLAUNCHED
	JSR PROT_EnableDisplay
	JMP INPUT_GET
KOAPLUGINLAUNCHED
	JMP *

PLUGIN_PRG_PATH
	JSR BUILDPLUGINNAME_PRG
	LDX #<PLUGINNAME
	LDY #>PLUGINNAME
	JSR PROT_SetNameZ			
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC PRGPLUGINEXISTS
	JMP PLUGINMISSING

PLUGINMISSING
	LDA #$02			; red
	LDX #<MSG_PLUGIN_MISSING
	LDY #>MSG_PLUGIN_MISSING
	JSR STATUS_LINE
	JSR PROT_EnableDisplay
	JMP INPUT_GET
UNKNOWNFILE
	LDA #$02			; red
	LDX #<MSG_UNSUPPORTED_FILE
	LDY #>MSG_UNSUPPORTED_FILE
	JSR STATUS_LINE
	JSR PROT_EnableDisplay
	JMP INPUT_GET
PRGPLUGINEXISTS	
	DELAYFRAMES	1	
	JSR PROT_CloseFile	
	
	JSR GETCURRENTROW	
	JSR PrepareFileNameParameter

	; FILE_PATH_BUF/PATHBUFFER now contains the selected media file's absolute path.
	; Keep that for the plugin to consume, but invoke the plugin executable itself.
	LDX #<PLUGINNAME
	LDY #>PLUGINNAME
	JSR PROT_SetNameZ
	LDX #$01
	JSR PROT_InvokeWithName

	JMP *

PROGRAM
	LDA CURPAGEINDEX
	JSR GETCURRENTROW
	LDY #$01		; flags: autorun
	JSR PROT_InvokeWithIndex
	BCC SUCCEEDINVOKE
	JSR PROT_EnableDisplay
SUCCEEDINVOKE
	JMP *


; Prints a 0-terminated string (X=lo, Y=hi) to bottom status line (row 24)
; Internal: write string X/Y to bottom line ($07C0), pad remainder with spaces.
;           Saves string ptr in $06/$07.
SL_WRITE
	STX $06
	STY $07
	LDY #$03			; col 0-2 = frame decoration, skip
_slw_copy
	LDA ($06), Y
	BEQ _slw_pad
	STA $07C0, Y
	INY
	CPY #$25			; 37 = stop before col 37-39 (frame, 3-char margin)
	BNE _slw_copy
	RTS
_slw_pad
	LDA #$20
_slw_padloop
	STA $07C0, Y
	INY
	CPY #$25			; 37
	BNE _slw_padloop
	RTS

; Internal: color non-space chars of string at $06/$07 in bottom line
;           color RAM ($DBC0) with color A. Uses no ZP temps: color in X, index in Y.
SL_COLOR
	TAX				; save color in X — avoids $FB-$FE (used by nav)
	LDY #$00
_slc_loop
	LDA ($06), Y
	BEQ _slc_done
	CMP #$20			; space = skip
	BEQ _slc_next
	TXA				; color
	STA $DBC0, Y
_slc_next
	INY
	CPY #$25			; 37 = same bound as SL_WRITE
	BNE _slc_loop
_slc_done
	RTS

; Print string X/Y (lo/hi) to bottom status line with color A.
; Chars $20 (space) are left uncolored; only non-space text gets the color.
STATUS_LINE
	PHA				; save color — SL_WRITE clobbers A
	JSR SL_WRITE
	PLA				; restore color
	JMP SL_COLOR

SPECIALCMD

	; INVOKE PLUGIN

	
GOBACK
	; Send ".." to the Arduino. Arduino navigates one level up and updates
	; its authoritative currentPath. C64 queries the new path via PROT_GetCurrentPath.
	LDA #>PARENTDIR
	TAY
	LDA #<PARENTDIR
	TAX
	JSR PROT_SetNameZ
	JSR PROT_ChangeDirectory
	BCS CHANGEDIRFAIL
	DELAYFRAMES 2
	RTS
	
	
ISPREVIOUSDIRECTORY
	LDY #$00
	LDA (NAMELOW), Y
	CMP #$2E
	BNE +
	INY
	LDA (NAMELOW), Y
	CMP #$2E
	BNE +
	CLC
	RTS
+
	SEC
	RTS
	
NEWCONTENT
; Update the screen with the new content got from micro

	JSR PROT_EnableDisplay
	JSR GETCURRENTROW
	JSR CLEARARROW
	JSR PRINTDIRHEADER	; 1. directory header row
	JSR PRINTPAGE		; 2. filenames + decorations + scroll indicators
	LDA CURSOR_GOTO_LAST	; cursor to last item? (UP across page boundary)
	BEQ _nc_first
	LDA #0
	STA CURSOR_GOTO_LAST
	LDX CURPAGEITEMS
	BEQ _nc_first		; guard: 0 items → cursor to row 0, avoid DEX underflow
	DEX			; last item index
	JMP _nc_setcursor
_nc_first
	LDX #0
_nc_setcursor
	JSR SETCURRENTROWHEAD
	JSR SETARROW

	CLI
	JMP INPUT_GET
  	
	RTS	

DIRREAD
;	LDA #$02
;	STA BORDER

;	DELAYFRAMES 10
	JSR PROT_EnableDisplay

	JSR PRINTDIRHEADER	; 1. directory header row
	JSR PRINTPAGE		; 2. filenames + decorations
	LDX #$00		;Puts the selector
	JSR SETCURRENTROWHEAD	;to the first entry in the
	JSR SETARROW		;list
	CLC
	RTS


	
WAITFRAMES
FD
	LDY #$90
-	
	CPY $D012
	BNE -
	LDY #50
-	
	DEY
	BNE - 
	
	DEX
	BNE FD
	RTS
	
SETFILENAME
	JSR GETCURRENTROW

	; Build absolute path in PATHBUFFER via PrepareFileNameParameter
	JSR PrepareFileNameParameter
	; (always succeeds — path fits PATH_MAX by design)

	; Set filename for PROT_InvokeWithName using null-terminated PATHBUFFER
	LDX #<PATHBUFFER
	LDY #>PATHBUFFER
	JSR PROT_SetNameZ
	CLC
	RTS

ISDIRECTORY
	LDA NAMESLO, X
	STA NAMELOW
	LDA NAMESHI, X
	STA NAMEHIGH
	LDY #31			; byte 31 = metadata type, ENTRY_TYPE_DIR is $04
	LDA (NAMELOW), Y
	CMP #$04
	RTS
			
SETARROW 	; Input : X (current row), Changed : A, Y, NAMELOW, NAMEHIGH
	; Pre-compute screen/color COLHIGH for fast swapping
	LDA COLHIGH
	PHA			; Save original for restore at end
	STA NAMELOW		; $FB = screen COLHIGH (temp)
	CLC
	ADC #$D4
	STA NAMEHIGH		; $FC = color COLHIGH (temp)
	; Draw white solid block cursor at col 2
	LDY #$00
	LDA #$A0		; Reversed space (solid block)
	STA (COLLOW),Y
	; Draw $40 char at col 3
	INY
	LDA #$40
	STA (COLLOW),Y
	; Set cursor + $40 colors to white in color RAM
	LDA NAMEHIGH
	STA COLHIGH
	LDY #$00
	LDA #$01
	STA (COLLOW),Y		; col 2 = white
	INY
	STA (COLLOW),Y		; col 3 = white
	; Switch back to screen RAM
	LDA NAMELOW
	STA COLHIGH
	; Reverse + color all chars (cols 4-35), incl. spaces ($20→$A0 solid block)
	LDY #$02
_SETARR_LOOP
	LDA (COLLOW),Y		; Read screen code
	ORA #$80		; Reverse (space $20→$A0, others: set bit 7)
	STA (COLLOW),Y		; Write to screen RAM
	LDA NAMEHIGH		; Switch to color RAM
	STA COLHIGH
	LDA #$01		; White
	STA (COLLOW),Y
	LDA NAMELOW		; Switch back to screen RAM
	STA COLHIGH
	INY
	CPY #$21		; col 33 = last extension char (end of reversed area)
	BNE _SETARR_LOOP
	; Restore original COLHIGH
	PLA
	STA COLHIGH
	RTS

CLEARARROW	; Input : X (current row), Changed : A, Y
	; Un-reverse screen codes for cols 4-35
	LDY #$02
_CLRARR_UNREV
	LDA (COLLOW),Y
	AND #$7F
	STA (COLLOW),Y
	INY
	CPY #$21		; col 33 = last extension char
	BNE _CLRARR_UNREV
	; Restore decoration based on position (X = current row)
	; (first item is now the dir header, all file items use middle or last style)
	LDY #$00
	INX
	CPX CURPAGEITEMS	; Last item? (X+1 == count)
	PHP			; Save Z flag
	DEX			; Restore X
	PLP			; Restore Z from CPX
	BEQ _CLRARR_LAST
	; Middle: vertical line + space
	LDA #$5D
	STA (COLLOW),Y		; col 2 = |
	INY
	LDA #$20
	STA (COLLOW),Y		; col 3 = space
	JMP _CLRARR_COLORS
_CLRARR_LAST
	; Last: reversed space + space
	LDA #$A0
	STA (COLLOW),Y		; col 2
	INY
	LDA #$20
	STA (COLLOW),Y		; col 3
_CLRARR_COLORS
	; Set colors: cols 2-3 = white, cols 4-35 = dark grey
	LDA COLHIGH
	PHA
	CLC
	ADC #$D4
	STA COLHIGH
	LDY #$00
	LDA #$01		; White for decoration
	STA (COLLOW),Y		; col 2
	INY
	STA (COLLOW),Y		; col 3
	INY
	LDA #$0B		; Dark grey for filename
_CLRARR_COL
	STA (COLLOW),Y
	INY
	CPY #$26		; col 38 = last content col
	BNE _CLRARR_COL
	; Restore screen RAM pointer
	PLA
	STA COLHIGH
	RTS
	
SETCURRENTROW	; Input : X (current row), Changed : None
	PHA
	STX CURRENTROW
	TXA
	PHA
	ASL
	TAX
	LDA COLS+2,X
	STA COLLOW
	INX
	LDA COLS+2,X
	STA COLHIGH	
	PLA
	TAX
	PLA
	RTS
	
SETCURRENTROWHEAD ; Input : X (current row), Changed : None
	PHA
	STX CURRENTROW
	TXA
	PHA
	ASL
	TAX
	LDA COLS+2,X
	CLC
	SBC #01
	STA COLLOW
	INX
	LDA COLS+2,X
	STA COLHIGH	
	PLA
	TAX
	PLA
	RTS
		
GETCURRENTROW	; Input : None, Output : X (current row)
	LDX CURRENTROW
	RTS	
	
; ------------------------------------------------------------
; PRINTASCIIFILENAME - ASCII to screen code filename printer
; ------------------------------------------------------------
; Display layout (col 3 = Y=0 base):
;   Directories : name 0-25 (26 chars max), 2 spaces at 26-27,
;                 "DIR" screen codes at 28-30, spaces 31-35
;   Files       : stem 0-25 (26 chars max, extension stripped),
;                 2-space gap at 26-27,
;                 extension at 28-30 (up to 3 chars),
;                 1 space at 31, tail spaces 32-35
;
; Entry format (32 bytes per GAMELIST slot):
;   bytes 0-30 : null-terminated ASCII filename
;   byte  31   : Arduino-provided ENTRY_TYPE_* metadata
;
; Input:  NAMELOW/HIGH = pointer to 32-byte entry
;         COLLOW/HIGH  = pointer to screen memory (col 4 of row)
; Output: None
; Changes: A, Y
; ZP temps: $8B (last dot pos, 0=none), $8C/$8D/$8E (ext ASCII, default $20)
; ------------------------------------------------------------
PRINTASCIIFILENAME
	; --- Check directory/file type flag (byte 31 of entry) ---
	LDY #31
	LDA (NAMELOW), Y
	AND #$04
	BEQ _paf_file

	; === DIRECTORY: print up to 26 chars, gap, "DIR" label, fill ===
_paf_dir
	LDY #0
_paf_dloop
	CPY #26
	BCS _paf_dfill		; >= 26 chars printed, fill spaces
	LDA (NAMELOW), Y
	BEQ _paf_dfill		; null terminator, fill spaces
	JSR _paf_conv		; ASCII -> screen code
	STA (COLLOW), Y
	INY
	JMP _paf_dloop
_paf_dfill
	LDA #$20		; pad name area to Y=26
_paf_dspace
	CPY #26
	BCS _paf_dgap
	STA (COLLOW), Y
	INY
	BNE _paf_dspace
_paf_dgap
	; 2-space gap at Y=26-27
	LDA #$20
	STA (COLLOW), Y
	INY
	STA (COLLOW), Y
	INY			; Y=28
	; "DIR" screen codes at Y=28-30 ($44,$49,$52 = D,I,R uppercase passthrough)
	LDA #$44		; D
	STA (COLLOW), Y
	INY
	LDA #$49		; I
	STA (COLLOW), Y
	INY
	LDA #$52		; R
	STA (COLLOW), Y
	INY			; Y=31
	; Fill Y=31-35 with spaces (space + MORE area)
	LDA #$20
_paf_dtail
	CPY #$24		; 36 total
	BCS _paf_ret
	STA (COLLOW), Y
	INY
	BNE _paf_dtail
_paf_ret
	RTS

	; === FILE: metadata type -> label; unknown files show "???" ===
_paf_file
	LDY #31
	LDA (NAMELOW), Y
	CMP #ENTRY_TYPE_PRG
	BEQ _paf_ext_prg
	CMP #ENTRY_TYPE_CRT
	BEQ _paf_ext_crt
	CMP #ENTRY_TYPE_KOA
	BEQ _paf_ext_koa
	CMP #ENTRY_TYPE_WAV
	BEQ _paf_ext_wav
	CMP #ENTRY_TYPE_CVD
	BEQ _paf_ext_cvd
	JMP _paf_ext_unknown

	; -- Print visible stem (source = dest = Y, stop at last dot, 26, or null) --
_paf_stem
	LDY #0
_paf_sloop
	CPY #26
	BCS _paf_stem_done	; 26 chars written, stop
	LDA $8B
	BEQ _paf_no_dot_stop
	TYA
	CMP $8B			; reached visible extension dot?
	BCS _paf_stem_done
_paf_no_dot_stop
	LDA (NAMELOW), Y
	BEQ _paf_stem_done
	JMP _paf_stem_write
_paf_stem_write
	JSR _paf_conv		; ASCII -> screen code
	STA (COLLOW), Y
	INY
	JMP _paf_sloop
_paf_stem_done
	; -- Pad stem area to position 26 with spaces --
	LDA #$20
_paf_pad21
	CPY #26
	BCS _paf_gap
	STA (COLLOW), Y
	INY
	BNE _paf_pad21
_paf_gap
	; 2-space gap at positions 26 and 27
	LDA #$20
	STA (COLLOW), Y		; position 26
	INY
	STA (COLLOW), Y		; position 27
	INY			; Y = 28
	; Extension characters at positions 28, 29, 30
	LDA $8C
	JSR _paf_conv
	STA (COLLOW), Y
	INY
	LDA $8D
	JSR _paf_conv
	STA (COLLOW), Y
	INY
	LDA $8E
	JSR _paf_conv
	STA (COLLOW), Y
	INY			; Y = 31
	; Space at position 31 (separator before MORE area)
	LDA #$20
	STA (COLLOW), Y
	INY			; Y = 32
	; Fill positions 32-35 with spaces (MORE overlay area)
_paf_tail
	CPY #$24		; 36 total
	BCS _paf_ret
	STA (COLLOW), Y
	INY
	BNE _paf_tail
	BEQ _paf_ret		; Y wrapped (impossible here, but safe)

_paf_ext_prg
	LDA #$50		; P
	STA $8C
	LDA #$52		; R
	STA $8D
	LDA #$47		; G
	JMP _paf_ext_done
_paf_ext_crt
	LDA #$43		; C
	STA $8C
	LDA #$52		; R
	STA $8D
	LDA #$54		; T
	JMP _paf_ext_done
_paf_ext_koa
	LDA #$4B		; K
	STA $8C
	LDA #$4F		; O
	STA $8D
	LDA #$41		; A
	JMP _paf_ext_done
_paf_ext_wav
	LDA #$57		; W
	STA $8C
	LDA #$41		; A
	STA $8D
	LDA #$56		; V
	JMP _paf_ext_done
_paf_ext_cvd
	LDA #$43		; C
	STA $8C
	LDA #$56		; V
	STA $8D
	LDA #$44		; D
	JMP _paf_ext_done
_paf_ext_unknown
	LDA #$3F		; ?
	STA $8C
	STA $8D
_paf_ext_done
	STA $8E
	LDA #0
	STA $8B
	LDY #0
_paf_dot_scan
	LDA (NAMELOW), Y
	BEQ _paf_dot_done
	CMP #$2E		; '.'
	BNE _paf_dot_next
	STY $8B
_paf_dot_next
	INY
	CPY #31			; scan visible name bytes only
	BNE _paf_dot_scan
_paf_dot_done
	JMP _paf_stem

	; --- ASCII to C64 screen code conversion ---
	; Input/Output: A    Changes: A only
_paf_conv
	CMP #$40		; '@'?
	BEQ _paf_at
	CMP #$41		; < 'A' ($20-$3F: space, digits, punct)?
	BCC _paf_cret		; as-is
	CMP #$5B		; < '[' ($41-$5A uppercase A-Z)?
	BCC _paf_cret		; uppercase: screen code = ASCII value
	CMP #$60		; < '`' ($5B-$5F: [ \ ] ^ _)?
	BCC _paf_sym
	CMP #$7B		; < '{' ($61-$7A lowercase a-z)?
	BCS _paf_cret		; >= $7B: as-is
	SEC
	SBC #$60		; lowercase -> screen $01-$1A
	RTS
_paf_sym
	SEC
	SBC #$40		; $5B-$5F -> screen $1B-$1F
	RTS
_paf_at
	LDA #$00		; '@' -> screen $00
_paf_cret
	RTS

CLEARLINE	; Input : None, Changed: Y, A
	LDY #$00
	LDA #$20	
ICLEARLINE		
	STA (COLLOW), Y
	INY
	CPY #$24		; 36 chars (col 3 to col 38)
	BNE ICLEARLINE
	RTS
	
	
FREQ    = 19704


PREINIT		; Input : None, Changed : A
	JSR DISABLEINTERRUPTS
	JSR KILLCIA
	JSR STARTMUSIC

	RTS


POSTINIT		; Input : None, Changed : A
	CLD
	LDA #$93
	JSR CHROUT
	LDA #$00 
	STA $D020
	LDA #$0B
	STA $D021
	JSR INITPC					
	RTS

INITPC
	LDX #$00
	LDA #$0F
CBL
	STA $D800,X
	STA $D900,X
	STA $DA00,X
	STA $DB00,X	
	INX
	BNE CBL
		
	RTS
	

STARTMUSIC
	;JSR COPYMUSIC
	;LDA #$00
	;JSR SIDINIT	
	RTS	


KILLCIA
	LDY #$7f    ; $7f = %01111111 
    STY $dc0d   ; Turn off CIAs Timer interrupts 
    STY $dd0d   ; Turn off CIAs Timer interrupts 
    LDA $dc0d   ; cancel all CIA-IRQs in queue/unprocessed 
    LDA $dd0d   ; cancel all CIA-IRQs in queue/unprocessed 
	RTS	

DISABLEINTERRUPTS
	LDY #$7f    ; $7f = %01111111 
    STY $dc0d   ; Turn off CIAs Timer interrupts 
    STY $dd0d   ; Turn off CIAs Timer interrupts 
    LDA $dc0d   ; cancel all CIA-IRQs in queue/unprocessed 
    LDA $dd0d   ; cancel all CIA-IRQs in queue/unprocessed 
	
; 	Change interrupt routines
	ASL $D019
	LDA #$00
	STA $D01A
	RTS

DISABLEDISPLAY
	LDA #$0B				;%00001011 ; Disable VIC display until the end of transfer
	STA $D011	
	RTS
ENABLEDISPLAY
	LDA #$1B				;%00001011 ; Disable VIC display until the end of transfer
	STA $D011	
	RTS	
	
SIDREG = $d400

		
	
COPYMUSIC
	LDX #$10		; Copy 16 blocks
	;Set source
	LDA #<SID
	STA $FB
	LDA #>SID
	STA $FC
	
	;Set target
	LDA #<SIDLOAD
	STA $FD
	LDA #>SIDLOAD
	STA $FE
	
	LDY #$00
COPYBLOCK	
	LDA ($FB), Y
	STA ($FD), Y
	INY
	BNE COPYBLOCK
	INC $FC
	INC $FE
	DEX
	BNE COPYBLOCK	
	RTS
	

	
	
PRINTPAGE	; Input : None, Changed : A, X, Y
	LDA CURPAGENAMELOW
	STA NAMELOW
	LDA CURPAGENAMEHIGH
	STA NAMEHIGH

	LDX #$00
	; Guard: skip print loop entirely when CURPAGEITEMS=0
	; Without this, the do-while loop executes 256 times (X wraps 1..255..0)
	CPX CURPAGEITEMS
	BEQ FINISH
SETCOL
	JSR SETCURRENTROW

	; Print filename using ASCII to screen code conversion
	; Filenames are ASCII from the SD-backed directory listing.
	; .TEXT in 64tass stores these strings in ASCII encoding.
	JSR PRINTASCIIFILENAME

	INX
	CPX CURPAGEITEMS
	BEQ FINISH
	LDA NAMELOW
	CLC
	ADC #$20		; advance by 32 (MAXFILENAMELENGTH)
	STA NAMELOW
	BCC NEXTFILE
	INC NAMEHIGH
NEXTFILE
	JMP SETCOL
FINISH
	CPX #$15		; 21 = MAXDIRITEMS
	BEQ ACTUALFINISH
	JSR SETCURRENTROW
	JSR CLEARLINE
	INX 
	CLV
	BVC FINISH
	
ACTUALFINISH
	JSR DRAWDECORATIONS
	JSR DRAW_SCROLL_INDICATORS
	LDX #COMMANDENTERMASK
	STX COMMANDBYTE
	RTS

; ------------------------------------------------------------
; DRAWDECORATIONS - Draw col 2-3 decorations for all menu rows
; First item:  reversed space ($A0) + horizontal line ($40), white
; Middle items: vertical line ($5D) + space, white
; Last item:   reversed space ($A0) + space, white
; Empty rows:  space + space, dark grey
; ------------------------------------------------------------
DRAWDECORATIONS
	LDX #$00
_DDEC_LOOP
	CPX #$15		; 21 = MAXDIRITEMS
	BEQ _DDEC_DONE
	JSR SETCURRENTROWHEAD	; COLLOW = col 2 of row X
	CPX CURPAGEITEMS
	BCS _DDEC_EMPTY		; >= item count -> empty row
	; Active item - determine middle or last
	; (first item is now the dir header, all file items use middle or last style)
	LDY #$00
	INX
	CPX CURPAGEITEMS	; Last item? (X+1 == count)
	PHP			; Save Z flag
	DEX			; Restore X
	PLP			; Restore Z from CPX
	BEQ _DDEC_LAST
	; Middle: vertical line + space, white
	LDA #$5D
	STA (COLLOW),Y		; col 2 = |
	INY
	LDA #$20
	STA (COLLOW),Y		; col 3 = space
	LDA #$01		; White
	BNE _DDEC_SETCOL	; Always taken
_DDEC_LAST
	; Last: reversed space + space, white
	LDA #$A0
	STA (COLLOW),Y		; col 2
	INY
	LDA #$20
	STA (COLLOW),Y		; col 3 = space
	LDA #$01		; White
	BNE _DDEC_SETCOL	; Always taken
_DDEC_EMPTY
	; Empty row: space + space, dark grey
	LDY #$00
	LDA #$20
	STA (COLLOW),Y
	INY
	STA (COLLOW),Y
	LDA #$0B		; Dark grey
_DDEC_SETCOL
	; Set color for col 2-3 (decoration, A = color value), then dark grey
	; for the entire filename area (cols 4-38).  Without this, the filename
	; area keeps whatever color the PETMATE background wrote, which can be
	; white for some rows — causing the first filename character to appear
	; white after a page load.
	STA NAMELOW		; Temp: save decoration color
	LDA COLHIGH
	PHA
	CLC
	ADC #$D4
	STA COLHIGH		; -> color RAM
	LDY #$00
	LDA NAMELOW
	STA (COLLOW),Y		; col 2 color (decoration)
	INY
	STA (COLLOW),Y		; col 3 color (decoration)
	INY			; Y=2 = col 4, first filename character
	LDA #$0B		; dark grey for all filename chars
_DDEC_NAMECOL
	STA (COLLOW),Y
	INY
	CPY #$26		; stop at Y=$26 (covers cols 4-38 = Y 2-37)
	BNE _DDEC_NAMECOL
	PLA
	STA COLHIGH		; -> screen RAM
	INX
	JMP _DDEC_LOOP
_DDEC_DONE
	RTS

; ------------------------------------------------------------
; DRAW_SCROLL_INDICATORS
; Called after PRINTPAGE to overlay scroll hints on rows 2 and 22.
; Row 2,  cols 35-38 ($0473): "MORE" if previous pages exist
; Row 22, cols 35-38 ($0793): "MORE" if next pages exist
;   M=$4D  O=$4F  R=$52  E=$45 (uppercase C64 screen codes)
;   Color: green ($05) via color RAM $D873 / $DB93
; Clobbers: A, Y
; ------------------------------------------------------------
DRAW_SCROLL_INDICATORS
	LDA PAGECOUNT
	CMP #1
	BEQ _dsi_done		; single page -> nothing to show

	; --- MORE on row 2, when previous page exists ---
	LDA CURPAGEINDEX
	BEQ _dsi_check_below
	LDA #$4D
	STA $0473		; M
	LDA #$4F
	STA $0474		; O
	LDA #$52
	STA $0475		; R
	LDA #$45
	STA $0476		; E
	LDA #$05		; green
	LDY #3
_dsi_up_col
	STA $D873,Y
	DEY
	BPL _dsi_up_col

_dsi_check_below
	; --- MORE on row 22, when next page exists ---
	LDA CURPAGEINDEX
	CLC
	ADC #1
	CMP PAGECOUNT		; CURPAGEINDEX+1 >= PAGECOUNT?
	BCS _dsi_done		; on last page -> nothing
	LDA #$4D
	STA $0793		; M
	LDA #$4F
	STA $0794		; O
	LDA #$52
	STA $0795		; R
	LDA #$45
	STA $0796		; E
	LDA #$05		; green
	LDY #3
_dsi_down_col
	STA $DB93,Y
	DEY
	BPL _dsi_down_col

_dsi_done
	RTS

; ------------------------------------------------------------
; LOAD_CUSTOM_CHARSET
; Copies CUSTOM_CHARSET (2KB, from CharPad binary export) to RAM at $3800-$3FFF.
; VIC bank 0, slot 7 = $3800 → $D018 already set to ORA #$0E by DISPLAYSCREENGRAPHICS.
; Must be called before screen is enabled (during init, display blanked).
; Clobbers: A, X
; ------------------------------------------------------------
LOAD_CUSTOM_CHARSET
	LDX #0
_lcc_p0
	LDA CUSTOM_CHARSET+$000,X
	STA $3800,X
	INX
	BNE _lcc_p0
_lcc_p1
	LDA CUSTOM_CHARSET+$100,X
	STA $3900,X
	INX
	BNE _lcc_p1
_lcc_p2
	LDA CUSTOM_CHARSET+$200,X
	STA $3A00,X
	INX
	BNE _lcc_p2
_lcc_p3
	LDA CUSTOM_CHARSET+$300,X
	STA $3B00,X
	INX
	BNE _lcc_p3
_lcc_p4
	LDA CUSTOM_CHARSET+$400,X
	STA $3C00,X
	INX
	BNE _lcc_p4
_lcc_p5
	LDA CUSTOM_CHARSET+$500,X
	STA $3D00,X
	INX
	BNE _lcc_p5
_lcc_p6
	LDA CUSTOM_CHARSET+$600,X
	STA $3E00,X
	INX
	BNE _lcc_p6
_lcc_p7
	LDA CUSTOM_CHARSET+$700,X
	STA $3F00,X
	INX
	BNE _lcc_p7
	RTS

; ------------------------------------------------------------
; PRINTDIRHEADER — print current dir on header row (row 1)
; Format: ■─/DIRNAME─■  (all inversed, white)
;         at root: ■─/ROOT─■
; Screen row 1: $0428-$044F  col2=$042A  col4=$042C
; Uses: NAMELOW/NAMEHIGH ($FB/$FC)
; ------------------------------------------------------------
PRINTDIRHEADER
	; ■ at col 1 (decoration adjacent to left frame)
	LDA #$A0
	STA $0429
	; ─ at col 2
	LDA #$40
	STA $042A
	; / reversed at col 3 (start of inverted area)
	LDA #$AF		; $2F|$80
	STA $042B

	; Read current path directly here (stable behavior from the proven flow).
	JSR PROT_GetCurrentPath
	; Check if at root: PATHBUFFER[1] == 0 means path is just "/"
	LDA PATHBUFFER+1
	BNE _pdh_subdir

	; At root: write "ROOT" reversed at col 4-7
	LDA #$D2		; R ($52|$80)
	STA $042C
	LDA #$CF		; O ($4F|$80)
	STA $042D
	LDA #$CF		; O
	STA $042E
	LDA #$D4		; T ($54|$80)
	STA $042F
	LDY #$04		; Y=4 -> place frame end at col 8-9
	JMP _pdh_done_copy

_pdh_subdir
	; Extract last directory component from PATHBUFFER
	; NAMELOW/NAMEHIGH will point to it after the call
	JSR ExtractLastDirname

	LDY #$00
_pdh_copy
	LDA (NAMELOW), Y
	BEQ _pdh_done_copy
	; ASCII -> screen code, same mapping as PRINTASCIIFILENAME.
	CMP #$40		; '@'?
	BEQ _pdh_at
	CMP #$41		; >= 'A'?
	BCC _pdh_noconv		; No -> $20-$3F: space, punctuation, digits, as-is
	CMP #$5B		; <= 'Z'?
	BCC _pdh_noconv		; yes -> uppercase screen codes are ASCII-compatible
	CMP #$60		; < '`'? ($5B-$5F: [, \, ], ^, _)
	BCC _pdh_symbol		; yes -> subtract $40
	CMP #$7B		; >= '{' ?
	BCS _pdh_noconv		; yes (backtick $60 or above 'z') -> as-is
	SEC
	SBC #$60		; lowercase $61-$7A -> screen code $01-$1A
	JMP _pdh_reverse
_pdh_symbol
	SEC
	SBC #$40		; $5B-$5F -> $1B-$1F
	JMP _pdh_reverse
_pdh_at
	LDA #$00		; @
_pdh_noconv
	; Reverse-video directory name inside the header bar.
_pdh_reverse
	ORA #$80		; reverse video
	STA $042C, Y		; col 4+Y
	INY
	CPY #$12		; max 18 chars (leaves room for ─■ before col 26)
	BCC _pdh_copy

_pdh_done_copy
	; ─■ normal after dirname
	LDA #$40		; ─ normal
	STA $042C, Y
	INY
	LDA #$A0		; ■ normal
	STA $042C, Y
	INY
	; fill rest with spaces up to col 25
	LDA #$20
_pdh_fill_sub
	CPY #$15		; stop before col 26 ($042C+20=col24+...)
	BCS _pdh_colors
	STA $042C, Y
	INY
	BNE _pdh_fill_sub

_pdh_colors
	; color RAM for row 1 cols 1..38 = $D829..$D84E → all white
	LDA #$01
	LDY #$00
_pdh_col
	STA $D829, Y
	INY
	CPY #$26		; 38 chars
	BNE _pdh_col
	RTS


; ------------------------------------------------------------
; PrepareFileNameParameter
;   Input : X = current row (set by caller via GETCURRENTROW)
;   Output: PATHBUFFER = "/current/path/filename\0" (null-terminated)
;           Carry clear always (path fits within PATH_MAX by design)
;   Modifies: A, X, Y, NAMELOW, NAMEHIGH, $08, $09, $0A
; ------------------------------------------------------------
PrepareFileNameParameter:
	; 1. Save current row, fetch current path → PATHBUFFER[0..63]
	STX $08
	JSR PROT_GetCurrentPath		; PATHBUFFER[0..63] = "/GAMES/ACTION\0..."
	LDX $08				; restore row

	; 2. Point NAMELOW/NAMEHIGH to selected filename (source)
	LDA NAMESLO, X
	STA NAMELOW
	LDA NAMESHI, X
	STA NAMEHIGH

	; 3. Find null terminator in PATHBUFFER (= path length)
	LDY #0
_pfp_scan
	LDA PATHBUFFER, Y
	BEQ _pfp_end_path
	INY
	CPY #PATH_MAX
	BNE _pfp_scan
_pfp_end_path
	; Y = length of path string (position of null byte)
	; If path is just "/" (Y==1), don't append an extra slash
	CPY #1
	BEQ _pfp_no_slash
	LDA #$2F			; '/'
	STA PATHBUFFER, Y
	INY
_pfp_no_slash
	; 4. Set $09/$0A = PATHBUFFER + Y (destination for filename append)
	TYA
	CLC
	ADC #<PATHBUFFER
	STA $09
	LDA #>PATHBUFFER
	ADC #0
	STA $0A
	; 5. Copy filename from (NAMELOW/NAMEHIGH)[Y] → ($09/$0A)[Y]
	LDY #0
_pfp_copy
	LDA (NAMELOW), Y
	BEQ _pfp_null_term
	STA ($09), Y
	INY
	CPY #MAXFILENAMELENGTH
	BNE _pfp_copy
_pfp_null_term
	LDA #0
	STA ($09), Y			; null-terminate

	; 6. Mirror PATHBUFFER → FILE_PATH_SHADOW ($FF00). The launch sequence wipes
	;    $033C-$043B, but $FF00+ survives because writes go to RAM under KERNAL
	;    ROM regardless of $01. Plugins recover the path from there with banking
	;    switched to $01=$35.
	LDY #0
_pfp_shadow
	LDA PATHBUFFER, Y
	STA FILE_PATH_SHADOW, Y
	BEQ _pfp_shadow_done
	INY
	CPY #FILE_PATH_SHADOW_MAX - 1
	BNE _pfp_shadow
	LDA #0
	STA FILE_PATH_SHADOW, Y		; force null-terminate at last slot
_pfp_shadow_done
	CLC
	RTS

; PUSHDIRNAME and POPDIRNAME removed: Arduino is now the single source
; of truth for the current path. C64 queries via PROT_GetCurrentPath.
	
DISPLAYPETGRAPHICS
	; set to 25 line text mode and turn on the screen
	lda #$1B
	sta $D011

	LDA CHARDATA
	STA $D020
	LDA CHARDATA+1
	STA $D021

	LDA #<CHARDATA+2
	STA $FB
	LDA #>CHARDATA+2
	STA $FC

	LDA #00
	STA $FD
	LDA #04
	STA $FE
	
	LDX #$04
	LDY #$00
-	
	LDA ($FB), Y
	STA ($FD),Y
	INY
	BNE -
	INC $FC	
	INC $FE
	DEX	
	BNE -
	
	
	LDA #<(CHARDATA+1002)
	STA $FB
	LDA #>(CHARDATA+1002)
	STA $FC

	LDA #00
	STA $FD
	LDA #$D8
	STA $FE
	
	LDX #$04
	LDY #$00
-	
	LDA ($FB), Y
	STA ($FD),Y
	INY
	BNE -
	INC $FC	
	INC $FE
	DEX	
	BNE -	
	RTS
	
DISPLAYSCREENGRAPHICS
	; Point VIC charset to $3800 (bank 0 slot 7) — custom charset loaded there by LOAD_CUSTOM_CHARSET
	LDA $D018
	AND #$F0		; preserve screen memory bits (upper nybble), clear charset bits
	ORA #$0E		; slot 7 → $3800-$3FFF in VIC bank 0
	STA $D018

	LDA PRGSCREENDATA
	STA $D020
	LDA PRGSCREENDATA+1
	STA $D021

	LDA #<PRGSCREENDATA+2
	STA $FB
	LDA #>PRGSCREENDATA+2
	STA $FC

	LDA #00
	STA $FD
	LDA #04
	STA $FE
	
	LDX #$04
	LDY #$00
-	
	LDA ($FB), Y
	STA ($FD),Y
	INY
	BNE -
	INC $FC	
	INC $FE
	DEX	
	BNE -
	
	
	LDA #<(PRGSCREENDATA+1002)
	STA $FB
	LDA #>(PRGSCREENDATA+1002)
	STA $FC

	LDA #00
	STA $FD
	LDA #$D8
	STA $FE
	
	LDX #$04
	LDY #$00
-	
	LDA ($FB), Y
	STA ($FD),Y
	INY
	BNE -
	INC $FC	
	INC $FE
	DEX	
	BNE -	
	RTS	

	
	
COMMANDBYTE	.BYTE 0
COMMANDARG  .BYTE 0, 0, 0, 0
CURRENTROW	.BYTE 0
CURSOR_GOTO_LAST .BYTE 0	; 1 = place cursor at last item after page load (UP across page boundary)
CURPAGENAMELOW	.BYTE <GAMELIST
CURPAGENAMEHIGH .BYTE >GAMELIST
BITPOS		.BYTE 0
ISMUSICPLAYING	.BYTE 0


COLS	
	.WORD $042B, $0453, $047B, $04A3, $04CB, $04F3, $051B, $0543, $056B, $0593
	.WORD $05BB, $05E3, $060B, $0633, $065B, $0683, $06AB, $06D3, $06FB, $0723
	.WORD $074B, $0773, $079B, $07C3, $0803

;	.WORD $0404, $042C, $0454, $047C, $04A4, $04CC, $04F4, $051C, $0544, $056C 
;	.WORD $0594, $05BC, $05E4, $060C, $0634, $065C, $0684, $06AC, $06D4, $06FC
;	.WORD $0724, $074C, $0774, $079C, $07C4
	
MAXFILENAMELENGTH = 32
MAXDIRITEMS = 21
-       = GAMELIST + range(0, MAXDIRITEMS * MAXFILENAMELENGTH, MAXFILENAMELENGTH)
NAMESLO   .byte <(-)
NAMESHI   .byte >(-)

PARENTDIR
	.TEXT ".."
	.FILL 30,0

SID
.include "../../Loader/CartLibStream.s"
.include "Filename.s"

PRGSCREENDATA
	; Generated from PETMATE petmate frame.asm by build.py (lowercase/uppercase charset)
	.binary "../../build/menu.bin"

CURPAGEINDEX	.BYTE 0

; Directory metadata and entries buffer
; IMPORTANT: CURPAGEITEMS and PAGECOUNT must be immediately before GAMELIST
; because DIRLOAD = GAMELIST - 2 points to CURPAGEITEMS
CURPAGEITEMS	.BYTE 5
PAGECOUNT		.BYTE 1
GAMELIST
DIRLOAD = GAMELIST - 2
; PROT_ReceiveFragment writes whole 256-byte pages starting at DIRLOAD.
; With 6 pages requested, the receive area must be 1536 bytes total including
; the 2-byte CURPAGEITEMS/PAGECOUNT header at DIRLOAD.
; PROT_ReadDirectory fills this from SD card via the Arduino.
	.FILL (DIRLOAD_TOTAL_BYTES - 2), 0


CHARDATA
	.BYTE $0C, $00

	.BYTE	$A0, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $D1, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0
	.BYTE	$A0, $A0, $A0, $A0, $C2, $A0, $69, $5F, $A0, $A0, $CA, $C9, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $D5, $C0, $C0, $F3, $A0, $C2, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $D5, $CB, $A0
	.BYTE	$A0, $A0, $A0, $A0, $C2, $69, $20, $20, $5F, $A0, $D7, $EB, $C3, $C3, $C3, $D1, $C3, $C3, $C3, $C3, $F2, $CB, $D7, $A0, $C2, $A0, $CA, $C3, $C3, $C3, $F3, $A0, $D7, $A0, $A0, $A0, $A0, $C2, $D7, $A0
	.BYTE	$A0, $A0, $69, $20, $20, $20, $E9, $DF, $20, $20, $20, $20, $20, $20, $5F, $E0, $69, $20, $20, $20, $20, $20, $20, $20, $20, $20, $5F, $D7, $A0, $69, $20, $20, $20, $20, $C3, $D1, $C3, $F1, $C3, $C3
	.BYTE	$A0, $A0, $20, $E9, $E3, $E3, $E3, $A0, $20, $A0, $A0, $A0, $A0, $DF, $20, $20, $20, $E9, $A0, $A0, $A0, $DF, $5F, $A0, $A0, $DF, $20, $5F, $69, $20, $E9, $A0, $A0, $20, $A0, $C2, $A0, $A0, $A0, $A0
	.BYTE	$C3, $C3, $20, $A0, $A0, $A0, $A0, $69, $20, $76, $A0, $A0, $A0, $A0, $DF, $20, $20, $A0, $A0, $A0, $A0, $A0, $DF, $5F, $A0, $A0, $DF, $20, $20, $E9, $A0, $A0, $69, $20, $C3, $F1, $C3, $C3, $C3, $C3
	.BYTE	$A0, $69, $20, $A0, $A0, $20, $20, $20, $20, $76, $A0, $A0, $5F, $A0, $A0, $DF, $20, $5F, $A0, $A0, $DF, $20, $20, $20, $5F, $A0, $A0, $DF, $E9, $A0, $A0, $69, $20, $E9, $A0, $A0, $A0, $A0, $A0, $A0
	.BYTE	$69, $20, $20, $A0, $A0, $A0, $A0, $A0, $A0, $76, $A0, $A0, $20, $5F, $A0, $A0, $DF, $20, $5F, $A0, $A0, $DF, $20, $20, $20, $5F, $A0, $A0, $A0, $A0, $69, $20, $E9, $A0, $A0, $A0, $A0, $A0, $A0, $C2
	.BYTE	$20, $E9, $20, $A0, $A0, $A0, $A0, $A0, $20, $76, $A0, $A0, $A0, $DF, $5F, $A0, $A0, $DF, $20, $5F, $A0, $A0, $DF, $20, $20, $20, $5F, $A0, $A0, $69, $20, $20, $20, $20, $20, $20, $A0, $5F, $D7, $C2
	.BYTE	$20, $5F, $20, $A0, $A0, $A0, $A0, $A0, $20, $76, $A0, $A0, $A0, $A0, $DF, $5F, $A0, $A0, $DF, $20, $5F, $A0, $A0, $DF, $20, $20, $20, $A0, $A0, $20, $E9, $A0, $69, $76, $A0, $A0, $DF, $A0, $5F, $CA
	.BYTE	$DF, $20, $20, $A0, $A0, $20, $20, $20, $20, $76, $A0, $A0, $20, $20, $20, $20, $5F, $A0, $A0, $DF, $20, $5F, $A0, $A0, $DF, $20, $20, $A0, $69, $E9, $A0, $69, $20, $76, $A0, $20, $5F, $DF, $20, $5F
	.BYTE	$A0, $DF, $20, $A0, $A0, $20, $20, $5F, $A0, $76, $A0, $A0, $76, $A0, $A0, $A0, $DF, $5F, $A0, $A0, $DF, $5F, $A0, $A0, $A0, $76, $75, $69, $E9, $A0, $69, $E9, $A0, $76, $A0, $E1, $DF, $5F, $DF, $20
	.BYTE	$C3, $C3, $20, $A0, $A0, $A0, $A0, $DF, $5F, $76, $A0, $A0, $76, $A0, $A0, $A0, $A0, $DF, $5F, $A0, $A0, $DF, $5F, $A0, $A0, $76, $75, $DF, $5F, $A0, $DF, $5F, $A0, $76, $A0, $E1, $A0, $20, $A0, $20
	.BYTE	$A0, $A0, $20, $E4, $E4, $E4, $E4, $A0, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $A0, $20, $20, $20, $A0, $DF, $5F, $A0, $DF, $20, $76, $A0, $20, $20, $20, $A0, $20
	.BYTE	$A0, $A0, $DF, $20, $20, $20, $5F, $69, $20, $20, $20, $E9, $C2, $E0, $E0, $E0, $A0, $C2, $A0, $A0, $D7, $A0, $A0, $C2, $A0, $DF, $20, $5F, $A0, $20, $5F, $A0, $DF, $76, $A0, $20, $20, $E9, $69, $20
	.BYTE	$A0, $A0, $A0, $C2, $A0, $DF, $20, $20, $E9, $A0, $A0, $E0, $C2, $E0, $E0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $D5, $F3, $A0, $A0, $DF, $20, $20, $20, $E9, $A0, $69, $76, $A0, $A0, $A0, $69, $A0, $E9
	.BYTE	$A0, $A0, $A0, $C2, $A0, $A0, $DF, $E9, $A0, $A0, $A0, $E0, $CA, $C0, $C0, $C9, $A0, $C2, $A0, $A0, $A0, $A0, $D1, $C2, $A0, $A0, $A0, $69, $20, $E9, $A0, $69, $20, $20, $20, $20, $20, $20, $E9, $A0
	.BYTE	$A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $E0, $A0, $A0, $A0, $A0, $C2, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $EB, $D1, $A0, $69, $20, $E9, $A0, $69, $A0, $E9, $A0, $C2, $A0, $A0, $A0, $A0, $A0
	.BYTE	$A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $D7, $A0, $A0, $D1, $C3, $C3, $C3, $DB, $C3, $CB, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $69, $20, $E9, $A0, $69, $20, $E9, $A0, $A0, $C2, $A0, $A0, $A0, $D5, $C3
	.BYTE	$A0, $A0, $A0, $CA, $C0, $F2, $C3, $C3, $C9, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $D1, $C3, $F3, $69, $20, $20, $20, $20, $20, $E9, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $C2, $A0
	.BYTE	$20, $C3, $C9, $A0, $A0, $C2, $20, $49, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $D1, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $C2, $A0
	.BYTE	$A0, $A0, $C2, $A0, $A0, $C2, $4A, $20, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $A0, $D7, $A0, $A0, $A0, $A0, $D1, $A0, $A0, $A0, $20, $20, $20, $A0, $A0, $20, $20, $20, $20, $20, $20, $20, $A0
	.BYTE	$A0, $A0, $C2, $A0, $A0, $C2, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $CA, $C0, $C0, $C0, $C0, $C0, $C0, $C0, $C0, $C0, $C0, $A0, $02, $19, $20, $C0, $20, $09, $2E, $12, $2E, $0F, $0E, $20, $C0
	.BYTE	$C3, $C3, $D1, $C3, $C3, $CB, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $20, $20, $20, $A0, $A0, $20, $20, $20, $20, $20, $20, $20, $A0
	.BYTE	$87, $86, $98, $D7, $86, $85, $92, $8F, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $A0, $C2, $A0, $A0, $A0, $A0, $A0, $A0, $A0

COLORDATA

	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0F, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0F, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0F, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0E, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0B, $0B, $0B, $0E, $0E, $0E, $06, $03, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0C, $0C, $0C, $0C, $0C, $0E, $0E, $0C, $0E, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0F, $0C, $0E, $03, $03, $03, $03, $03, $0E, $03, $03, $03, $03, $03, $0C, $0C, $0E, $03, $03, $03, $03, $03, $03, $03, $03, $03, $0C, $0C, $0C, $0C, $03, $03, $03, $0E, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0E, $0D, $0D, $0D, $0D, $0D, $0E, $0D, $0D, $0D, $0D, $0D, $0D, $0E, $0E, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0D, $0C, $0C, $0D, $0D, $0D, $0D, $0E, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0E, $07, $07, $0E, $0E, $0E, $0E, $07, $07, $07, $07, $07, $07, $07, $0E, $07, $07, $07, $07, $0E, $0E, $0E, $07, $07, $07, $07, $07, $07, $07, $07, $0E, $0B, $0B, $0B, $0B, $0B, $0B, $0B
	.BYTE	$0C, $0E, $0B, $0F, $0F, $00, $00, $00, $00, $0F, $0F, $0F, $0E, $0F, $0F, $0F, $0F, $0E, $0F, $0F, $0F, $0F, $0E, $0E, $0E, $0F, $0F, $0F, $0F, $0F, $0F, $0E, $0C, $0C, $0F, $0C, $0B, $0C, $0F, $0C
	.BYTE	$0C, $0C, $0B, $01, $01, $01, $01, $01, $0E, $01, $01, $01, $01, $01, $01, $01, $01, $01, $0E, $01, $01, $01, $01, $0E, $0E, $0E, $01, $01, $01, $01, $01, $0E, $0E, $0E, $0E, $0E, $00, $0C, $0C, $0C
	.BYTE	$0C, $0B, $0B, $0A, $0A, $0A, $0A, $0A, $0E, $0A, $0A, $0A, $0A, $0A, $0A, $0A, $0A, $0A, $0A, $0E, $0A, $0A, $0A, $0A, $0E, $06, $06, $0A, $0A, $01, $01, $01, $01, $01, $01, $01, $01, $00, $0C, $0C
	.BYTE	$0C, $0E, $0B, $02, $02, $0E, $0E, $0E, $0E, $02, $02, $02, $0E, $0E, $0E, $0E, $02, $02, $02, $02, $0E, $02, $02, $02, $02, $0E, $06, $02, $02, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $0C
	.BYTE	$0C, $0C, $0E, $04, $04, $0E, $0E, $0C, $0C, $04, $04, $04, $0C, $0C, $0C, $0C, $0C, $04, $04, $04, $04, $04, $04, $04, $04, $0C, $0C, $04, $01, $01, $01, $0C, $0C, $01, $01, $0C, $0C, $01, $01, $0C
	.BYTE	$0C, $0C, $0E, $0E, $0E, $0E, $0E, $0E, $0B, $0E, $0E, $0E, $0B, $0B, $0B, $0B, $0B, $0B, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0B, $0B, $0E, $03, $03, $03, $0B, $0B, $03, $03, $0B, $0B, $0B, $03, $0C
	.BYTE	$0C, $0C, $0E, $06, $06, $06, $06, $06, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $00, $0E, $06, $06, $06, $06, $0E, $0E, $0E, $01, $0E, $0E, $01, $01, $01, $0E, $0C
	.BYTE	$0C, $0C, $0C, $0E, $0E, $0E, $0B, $06, $0E, $0E, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0E, $06, $06, $01, $0E, $0E, $0E, $0E, $0E, $01, $01, $0E, $0E, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $01, $01, $01, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $0E, $00, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0E, $0E, $0E, $01, $01, $01, $01, $01, $01, $0C, $0C
	.BYTE	$0B, $0B, $0B, $0C, $0B, $0B, $0B, $0B, $0B, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $06, $06, $06, $00, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $06, $06, $06, $0E, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0E, $0E, $0E, $0E, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0F, $0C, $0B, $0C, $0C, $0F, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0F, $0C, $0F, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $00, $0C, $0C, $0C, $0C, $00, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0B, $0B, $0B, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $00, $01, $01, $0C, $0C, $0C, $01, $01, $01, $01, $01, $01, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0F, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $00, $0C, $0C, $0C, $0C, $00, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C
	.BYTE	$0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0C, $0B, $0C, $0C, $0C

; ------------------------------------------------------------
; UI strings (0-terminated)
; ------------------------------------------------------------
.enc "screen"		; .TEXT strings below use C64 screen code encoding (A=$01, etc.)
MSG_PATH_TOO_LONG
	.TEXT "   PATH TOO LONG"
	.BYTE 0

MSG_SD_READ_ERR
	.TEXT "   SD READ ERROR"
	.BYTE 0

MSG_CD_ERROR
	.TEXT "   CD FAILED"
	.BYTE 0

MSG_PLUGIN_MISSING
	.TEXT "   PLUGIN MISSING"
	.BYTE 0

.enc "none"		; ASCII screen bytes for the custom mixed-case charset.
MSG_UNSUPPORTED_FILE
	.TEXT "   UNSUPPORTED FILE"
	.BYTE 0
.enc "none"		; restore default encoding

; Protocol scratch buffer used by PROT_GetCurrentPath.
PLUGIN_HEADER
	.FILL 256

; Scroll rate limiter: ~100ms busy-wait (PAL ~985kHz: 80 × 250 × 5 = 100000 cycles).
; Called after UP/DOWN single-row scroll to limit continuous-scroll to ~10 rows/sec.
SCROLL_DELAY
	LDX #80
_sd_outer
	LDY #250
_sd_inner
	DEY
	BNE _sd_inner
	DEX
	BNE _sd_outer
	RTS

; Custom charset data (2KB, standard C64 mixed-case layout).
; LOAD_CUSTOM_CHARSET copies this to $3800-$3FFF (VIC bank 0, slot 7) at startup.
CUSTOM_CHARSET
	.binary "mixed case chars.bin"

	
