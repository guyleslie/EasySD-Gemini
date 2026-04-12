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
DIRLOAD_PAGES    = 6
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

; DEBUG mode flag - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Default production builds should define DEBUG=0 explicitly


	
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

.if DEBUG = 1
	JSR DEBUG_Init		; Initialize DEBUG dump area ($CF00)
.endif

	JSR DISPLAYPETGRAPHICS
	DELAYFRAMES 75

	JSR PROT_DisableDisplay
	JSR LOAD_CUSTOM_CHARSET		; copy custom charset to $3800, then update $D018
	JSR DISPLAYSCREENGRAPHICS
	LDA #$80
	STA $028A		; RPTFLG: repeat only cursor/function keys (enables held UP/DOWN scrolling)
.if DEBUG = 0 
	JSR PROT_StartTalking
.else
	NOP
	NOP
	NOP
.endif		
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
	
.if DEBUG = 0
	JSR PROT_ReadDirectory
	BCC _dir_ok
	LDA #$02			; red
	LDX #<MSG_SD_READ_ERR
	LDY #>MSG_SD_READ_ERR
	JSR STATUS_LINE
_dir_ok
.else
	JSR MOCK_InitReadDirectory
.endif

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
.if DEBUG = 1
	JSR MOCK_GoBack
.endif
	JSR GOBACK
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
.if DEBUG = 0
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
.endif

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
.if DEBUG = 0
	; Set filename: NAMELOW/NAMEHIGH point to selected dir's record (set by ISDIRECTORY)
	; Record format: bytes 0-62 = null-terminated ASCII dirname, byte 63 = type
	LDX NAMELOW
	LDY NAMEHIGH
	JSR PROT_SetNameZ		; sets KERNAL_FILENAME_LOW/LENGTH from null-terminated name
	JSR PROT_ChangeDirectory
	BCS CHANGEDIRFAIL
.else
	JSR MOCK_EnterDir
.endif

	
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
.if DEBUG = 0
	JSR PROT_ReadDirectoryNC
	BCC _dirNC_ok
	LDA #$02			; red
	LDX #<MSG_SD_READ_ERR
	LDY #>MSG_SD_READ_ERR
	JSR STATUS_LINE
_dirNC_ok
.else
	JSR MOCK_ReadDirectory
.endif
	
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
	TAY
	LDA NAMESHI, X
	TAX
	TYA

	JSR CHECKFILENAME
	JSR ISPRG
	BCC PROGRAM
	CMP #TYPE_PROGRAM
	BEQ PROGRAM
	CMP #TYPE_CHECK_PLUGIN
	BEQ PLUGIN
	
	; ERROR
-	
	INC $D020
	JMP - 
PLUGIN	
	JSR BUILDPLUGINNAME_BIN
	LDX #<PLUGINNAME
	LDY #>PLUGINNAME
	JSR PROT_SetNameZ			
	
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC BINPLUGINEXISTS
	
	DELAYFRAMES 1
	
	JSR BUILDPLUGINNAME_PRG
	LDX #<PLUGINNAME
	LDY #>PLUGINNAME
	JSR PROT_SetNameZ			
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC PRGPLUGINEXISTS
	JMP PROGRAM
	

	
BINPLUGINEXISTS
	DELAYFRAMES	20

		; ------------------------------------------------------------
		; BIN Plugin loader (plugin file is PRG-format)
		;
		; FIXES:
		;  1) Remove hardcoded page count (LDA #15)
		;  2) Do NOT lose bytes 2..255 of PRG payload
		;  3) Load exact payload size using PROT_GetInfoForFile + LoadFileBySize
		;
		; Algorithm:
		;   - Read first 256 bytes to PLUGIN_HEADER to get load address
		;   - Query file size, copy size into PROT_FILE_SIZE_* ($80-$83)
		;   - Seek to offset 2 (skip PRG header) and load full payload to load address
		; ------------------------------------------------------------

		; Step 1: Read first page (contains PRG load address)
	LDA #<PLUGIN_HEADER
	STA ZP_IRQ_API_DATA_LO
	LDA #>PLUGIN_HEADER
	STA ZP_IRQ_API_DATA_HI
	LDA #1			; Read 1 page (256 bytes) for header
	STA ZP_IRQ_API_DATA_LENGTH

	JSR PROT_DisableDisplay

	; Enable cartridge ROM access before reading
	CART_ROM_ENABLE

		LDY #$00
	JSR PROT_ReadFileNoCallback

	; Restore normal configuration
	CART_ROM_RESTORE

		; Step 2: Parse PRG load address (first 2 bytes)
	LDA PLUGIN_HEADER
	STA PLUGIN_LOAD_ADDR_LO
		STA ZP_IRQ_API_DATA_LO		; Target load address for payload
	LDA PLUGIN_HEADER+1
	STA PLUGIN_LOAD_ADDR_HI
	STA ZP_IRQ_API_DATA_HI

		; Step 3: Get file size (FAT directory entry) so we can load exact bytes
		; Reuse PLUGIN_HEADER buffer to receive the 256-byte info block.
		LDA #<PLUGIN_HEADER
		STA ZP_IRQ_API_DATA_LO
		LDA #>PLUGIN_HEADER
		STA ZP_IRQ_API_DATA_HI
		LDY #$00
		CART_ROM_ENABLE
		JSR PROT_GetInfoForFile
		CART_ROM_RESTORE
		BCS BINPLUGIN_LOAD_ERROR_INFO	; If GetInfo failed, abort

		; Extract 32-bit file size (offset 28..31 in first 32 bytes of dir entry)
		LDA PLUGIN_HEADER+28
		STA ZP_LOADFILE_API_SIZE0		; $80
		LDA PLUGIN_HEADER+29
		STA ZP_LOADFILE_API_SIZE1		; $81
		LDA PLUGIN_HEADER+30
		STA ZP_LOADFILE_API_SIZE2		; $82
		LDA PLUGIN_HEADER+31
		STA ZP_LOADFILE_API_SIZE3		; $83

		; Step 4: Load full PRG payload (skip 2-byte header) to PLUGIN_LOAD_ADDR
		LDA #$02
		STA ZP_LOADFILE_API_SKIP_LO		; $84
		LDA #$00
		STA ZP_LOADFILE_API_SKIP_HI		; $85

		CART_ROM_ENABLE
		JSR LoadFileBySize
		CART_ROM_RESTORE
		BCS BINPLUGIN_LOAD_ERROR_LOAD	; If load failed, abort

	
; ------------------------------------------------------------
; BIN Plugin load error handlers
; ------------------------------------------------------------
BINPLUGIN_LOAD_ERROR_INFO:
.if DEBUG = 1
	LDA #$02				; Error code 2 = PROT_GetInfoForFile failed
	JSR DEBUG_SetError
	JSR DEBUG_Break
.endif
	JSR PROT_CloseFile
	JSR PROT_EnableDisplay
	JMP INPUT_GET

BINPLUGIN_LOAD_ERROR_LOAD:
.if DEBUG = 1
	LDA #$03				; Error code 3 = payload load failed (LoadFileBySize sets 1 internally too)
	JSR DEBUG_SetError
	JSR DEBUG_Break
.endif
	JSR PROT_CloseFile
	JSR PROT_EnableDisplay
	JMP INPUT_GET

LDA #1
	STA $D020

	;JSR PROT_EnableDisplay

	DELAYFRAMES	1
	JSR PROT_CloseFile

	JSR PROT_EnableDisplay

	JSR GETCURRENTROW

	JSR PrepareFileNameParameter

	; Jump to plugin entry point (indirect jump using load address)
	JMP (PLUGIN_LOAD_ADDR_LO)	

		
PRGPLUGINEXISTS	
	DELAYFRAMES	1	
	JSR PROT_CloseFile	
	
	JSR GETCURRENTROW	
	JSR PrepareFileNameParameter

	JSR PROT_InvokeWithName

	JMP *

PROGRAM
.if DEBUG = 1
	LDA #$02
	STA BORDER
.endif
	JSR GETCURRENTROW
	;Setting name of the file
	JSR SETFILENAME	
.if DEBUG = 0
	; If it's a .tap, offer choice: Convert+Run (default) or Save only.
	JSR IS_TAP_SELECTED
	BEQ +
	; --- TAP path ---
	JSR TAP_CHOICE
	; X now holds flags for PROT_InvokeWithName (bit0=autorun)
	JSR PROT_InvokeWithName
	BCC TAP_INVOKE_OK
	; Error: A holds error code
	JSR TAP_SHOW_ERROR
	JSR PROT_EnableDisplay
	JMP INPUT_GET
TAP_INVOKE_OK
	; If save-only (bit0=0), stay in menu and show success.
	TXA
	AND #$01
	BNE TAP_AUTORUN
	LDA #$0B			; dark gray
	LDX #<MSG_TAP_SAVED
	LDY #>MSG_TAP_SAVED
	JSR STATUS_LINE
	JSR PROT_EnableDisplay
	JMP INPUT_GET
TAP_AUTORUN
	; Auto-run path: the micro will reset C64 and load the converted PRG.
	JMP *

	; --- Non-TAP default path ---
+	;Invoking with name
	LDX #$01		; flags: autorun
	JSR PROT_InvokeWithName
	BCC SUCCEEDINVOKE
	JSR PROT_EnableDisplay
SUCCEEDINVOKE
	JMP *
.else
	JMP MOCK_PrgExecute
.endif


; ------------------------------------------------------------
; TAP helpers
; ------------------------------------------------------------

; Returns Z=1 if selected filename ends with .tap (case-insensitive PETSCII)
IS_TAP_SELECTED
	JSR GETCURRENTROW
	LDA NAMESLO, X
	STA NAMELOW
	LDA NAMESHI, X
	STA NAMEHIGH
	; find last non-zero char within 31 bytes
	LDY #$1E			; start from 30
TAP_SCAN_LOOP
	LDA (NAMELOW), Y
	BEQ TAP_SCAN_DEC
	JMP TAP_SCAN_CHECK
TAP_SCAN_DEC
	DEY
	BPL TAP_SCAN_LOOP
	LDA #$00
	RTS
TAP_SCAN_CHECK
	; need at least 4 chars: . t a p
	CPY #$03
	BCC TAP_SCAN_NO
	; dot
	LDA (NAMELOW), Y
	AND #$DF
	CMP #$50			; 'P'
	BNE TAP_SCAN_NO
	DEY
	LDA (NAMELOW), Y
	AND #$DF
	CMP #$41			; 'A'
	BNE TAP_SCAN_NO
	DEY
	LDA (NAMELOW), Y
	AND #$DF
	CMP #$54			; 'T'
	BNE TAP_SCAN_NO
	DEY
	LDA (NAMELOW), Y
	CMP #$2E			; '.'
	BNE TAP_SCAN_NO
	LDA #$01
	RTS
TAP_SCAN_NO
	LDA #$00
	RTS


; Waits for user choice. Returns X flags for PROT_InvokeWithName.
; Default: Convert+Run (X=$01). Save-only: X=$00.
TAP_CHOICE
	LDA #$0B			; dark gray
	LDX #<MSG_TAP_PROMPT
	LDY #>MSG_TAP_PROMPT
	JSR STATUS_LINE
	JSR PROT_EnableDisplay
TAP_CHOICE_WAIT
	JSR SCNKEY
	JSR GETIN
	BEQ TAP_CHOICE_WAIT
	CMP #$53			; 'S'
	BEQ TAP_SAVE
	CMP #$73			; 's'
	BEQ TAP_SAVE
	CMP #$0D			; RETURN -> autorun
	BEQ TAP_RUN
	CMP #$43			; 'C'
	BEQ TAP_RUN
	CMP #$63			; 'c'
	BEQ TAP_RUN
	JMP TAP_CHOICE_WAIT
TAP_SAVE
	LDX #$00
	RTS
TAP_RUN
	LDX #$01
	RTS


; A contains error code from PROT_InvokeWithName (carry set)
TAP_SHOW_ERROR
	CMP #$12			; TAP_UNSUPPORTED
	BEQ _uns
	CMP #$13			; TAP_BAD_TAP
	BEQ _bad
	CMP #$14			; TAP_WRITE_FAILED
	BEQ _wr
	LDA #$02			; red
	LDX #<MSG_TAP_FAIL
	LDY #>MSG_TAP_FAIL
	JMP STATUS_LINE
_uns
	LDA #$02			; red
	LDX #<MSG_TAP_UNSUPPORTED
	LDY #>MSG_TAP_UNSUPPORTED
	JMP STATUS_LINE
_bad
	LDA #$02			; red
	LDX #<MSG_TAP_BAD
	LDY #>MSG_TAP_BAD
	JMP STATUS_LINE
_wr
	LDA #$02			; red
	LDX #<MSG_TAP_WRITE
	LDY #>MSG_TAP_WRITE
	JMP STATUS_LINE


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
.if DEBUG = 0
	JSR PROT_ChangeDirectory
	BCS CHANGEDIRFAIL
.endif
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
.if DEBUG = 1
	INC BORDER
.endif

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

.if DEBUG = 1
	; DEBUG: dump filename for diagnostics
	LDA NAMESLO, X
	STA $06
	LDA NAMESHI, X
	STA $07
	JSR DEBUG_DumpFilename
.endif

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
	LDY #63			; byte 63 = type flag (0x04=dir, 0x00=file)
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
	CPY #$22		; 34 = end of filename area
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
	CPY #$22
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
	CPY #$22
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
; Converts ASCII filenames to uppercase screen codes for the
; lowercase/uppercase charset mode.
;
; ASCII $20-$3F (numbers/symbols) → screen code as-is
; ASCII $41-$5A (uppercase A-Z)   → screen code $41-$5A (uppercase in lc/uc)
; ASCII $61-$7A (lowercase a-z)   → screen code $41-$5A (forced uppercase)
;
; Input:  NAMELOW/HIGH = pointer to ASCII filename
;         COLLOW/HIGH = pointer to screen memory position
; Output: None
; Changes: A, Y
; ------------------------------------------------------------
PRINTASCIIFILENAME
	LDY #$00
FILENAMEPRINT_A
	LDA (NAMELOW), Y    ; Read ASCII character
	BNE NOTEND_A        ; If not null terminator, continue
	LDA #$20            ; Replace null with space
	JMP WRITECHAR_A
NOTEND_A
	CMP #$5B            ; >= '['?
	BCC WRITECHAR_A     ; No → $20-$5A: space, punctuation, digits, A-Z, as-is
	CMP #$60            ; < '`' ? ($5B-$5F: [, \, ], ^, _)
	BCC _paf_bracket    ; yes → subtract $40 to get SC $1B-$1F
	CMP #$7B            ; >= '{' ?
	BCS WRITECHAR_A     ; yes (backtick $60 or above 'z') → as-is
	SEC
	SBC #$60            ; Lowercase $61-$7A → C64 screen codes $01-$1A (A-Z)
	JMP WRITECHAR_A
_paf_bracket
	SEC
	SBC #$40            ; $5B→$1B ([), $5C→$1C (£), $5D→$1D (]), $5E→$1E (↑), $5F→$1F (↓)
WRITECHAR_A
	STA (COLLOW), Y     ; Write to screen memory
	INY
	CPY #$1A            ; Print 26 characters (cols 4-29)
	BNE FILENAMEPRINT_A
	; Pad cols 30-35 with spaces so scroll indicators can overwrite cleanly
	LDA #$20
_fname_pad
	STA (COLLOW), Y
	INY
	CPY #$20            ; 32 total
	BNE _fname_pad
	RTS

CLEARLINE	; Input : None, Changed: Y, A
	LDY #$00
	LDA #$20	
ICLEARLINE		
	STA (COLLOW), Y
	INY
	CPY #$20
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
SETCOL
	JSR SETCURRENTROW

	; Print filename using ASCII to screen code conversion
	; Works for both DEBUG (mock data) and release (SD card data) modes
	; because both use ASCII encoding (.TEXT directive in 64tass)
	JSR PRINTASCIIFILENAME
	
	INX
	CPX CURPAGEITEMS
	BEQ FINISH	
	LDA NAMELOW
	CLC
	ADC #$40		; advance by 64 (MAXFILENAMELENGTH)
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
	; Set color for cols 2-3 (A = color value)
	STA NAMELOW		; Temp: save color
	LDA COLHIGH
	PHA
	CLC
	ADC #$D4
	STA COLHIGH		; -> color RAM
	LDY #$00
	LDA NAMELOW
	STA (COLLOW),Y		; col 2 color
	INY
	STA (COLLOW),Y		; col 3 color
	PLA
	STA COLHIGH		; -> screen RAM
	INX
	JMP _DDEC_LOOP
_DDEC_DONE
	RTS

; ------------------------------------------------------------
; DRAW_SCROLL_INDICATORS
; Called after PRINTPAGE to overlay scroll hints on rows 2 and 22.
; Row 2,  cols 30-35 ($046E): " ↑MORE" if previous pages exist
; Row 22, cols 30-35 ($078E): " vMORE" if next pages exist
;   ↑ = $1E (screen code for PETSCII $5E),  v = $16 (placeholder — replace with custom char later)
;   M=$0D  O=$0F  R=$12  E=$05 (C64 screen codes)
;   Color: green ($05) via color RAM $D86E / $DB8E
; Clobbers: A, Y
; ------------------------------------------------------------
DRAW_SCROLL_INDICATORS
	LDA PAGECOUNT
	CMP #1
	BEQ _dsi_done		; single page → nothing to show

	; --- ↑MORE on row 2, when previous page exists ---
	LDA CURPAGEINDEX
	BEQ _dsi_check_below
	LDY #0
	LDA #$20
	STA $046E,Y		; space
	INY
	LDA #$1E
	STA $046E,Y		; ↑ (screen code $1E = PETSCII $5E)
	INY
	LDA #$0D
	STA $046E,Y		; M
	INY
	LDA #$0F
	STA $046E,Y		; O
	INY
	LDA #$12
	STA $046E,Y		; R
	INY
	LDA #$05
	STA $046E,Y		; E
	LDA #$05		; green
	LDY #5
_dsi_up_col
	STA $D86E,Y
	DEY
	BPL _dsi_up_col

_dsi_check_below
	; --- vMORE on row 22, when next page exists ---
	LDA CURPAGEINDEX
	CLC
	ADC #1
	CMP PAGECOUNT		; CURPAGEINDEX+1 >= PAGECOUNT?
	BCS _dsi_done		; on last page → nothing
	LDY #0
	LDA #$20
	STA $078E,Y		; space
	INY
	LDA #$1F
	STA $078E,Y		; ↓ (custom char $1F from CharPad charset)
	INY
	LDA #$0D
	STA $078E,Y		; M
	INY
	LDA #$0F
	STA $078E,Y		; O
	INY
	LDA #$12
	STA $078E,Y		; R
	INY
	LDA #$05
	STA $078E,Y		; E
	LDA #$05		; green
	LDY #5
_dsi_down_col
	STA $DB8E,Y
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
	; ■ at col 2 (normal, same as file row decoration)
	LDA #$A0
	STA $042A
	; ─ at col 3 (normal)
	LDA #$40
	STA $042B
	; / reversed at col 4 (start of inverted area)
	LDA #$AF		; $2F|$80
	STA $042C

.if DEBUG = 0
	; Ask Arduino for current path → PATHBUFFER[0..63]
	JSR PROT_GetCurrentPath
.else
	JSR MOCK_GetCurrentPath
.endif
	; Check if at root: PATHBUFFER[1] == 0 means path is just "/"
	LDA PATHBUFFER+1
	BNE _pdh_subdir

	; At root: write "ROOT" reversed at col 5-8
	LDA #$92		; R ($12|$80) — screen code $12, inverted
	STA $042D
	LDA #$8F		; O ($0F|$80) — screen code $0F, inverted
	STA $042E
	LDA #$8F		; O
	STA $042F
	LDA #$94		; T ($14|$80) — screen code $14, inverted
	STA $0430
	LDY #$04		; Y=4 → place ─■ at col 9-10
	JMP _pdh_done_copy

_pdh_subdir
	; Extract last directory component from PATHBUFFER
	; NAMELOW/NAMEHIGH will point to it after the call
	JSR ExtractLastDirname

	LDY #$00
_pdh_copy
	LDA (NAMELOW), Y
	BEQ _pdh_done_copy
	; ASCII → uppercase screen code
	CMP #$61
	BCC _pdh_noconv
	CMP #$7B
	BCS _pdh_noconv
	SEC
	SBC #$60		; lowercase $61-$7A → screen code $01-$1A
_pdh_noconv
	ORA #$80		; reverse video
	STA $042D, Y		; col 5+Y
	INY
	CPY #$12		; max 18 chars (leaves room for ─■ before col 26)
	BCC _pdh_copy

_pdh_done_copy
	; ─■ normal after dirname
	LDA #$40		; ─ normal
	STA $042D, Y
	INY
	LDA #$A0		; ■ normal
	STA $042D, Y
	INY
	; fill rest with spaces up to col 25
	LDA #$20
_pdh_fill_sub
	CPY #$15		; stop before col 26 ($042D+20=col25)
	BCS _pdh_colors
	STA $042D, Y
	INY
	BNE _pdh_fill_sub

_pdh_colors
	; color RAM for row 1 cols 2..39 = $D82A..$D84F → all white
	LDA #$01
	LDY #$00
_pdh_col
	STA $D82A, Y
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
.if DEBUG = 0
	STX $08
	JSR PROT_GetCurrentPath		; PATHBUFFER[0..63] = "/GAMES/ACTION\0..."
.else
	STX $08
	JSR MOCK_GetCurrentPath		; PATHBUFFER[0..63] = MOCK_CURRENT_PATH copy
.endif
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
	.WORD $042C, $0454, $047C, $04A4, $04CC, $04F4, $051C, $0544, $056C , $0594
	.WORD $05BC, $05E4, $060C, $0634, $065C, $0684, $06AC, $06D4, $06FC , $0724
	.WORD $074C, $0774, $079C, $07C4, $0804

;	.WORD $0404, $042C, $0454, $047C, $04A4, $04CC, $04F4, $051C, $0544, $056C 
;	.WORD $0594, $05BC, $05E4, $060C, $0634, $065C, $0684, $06AC, $06D4, $06FC
;	.WORD $0724, $074C, $0774, $079C, $07C4
	
MAXFILENAMELENGTH = 64
MAXDIRITEMS = 21
-       = GAMELIST + range(0, MAXDIRITEMS * MAXFILENAMELENGTH, MAXFILENAMELENGTH)
NAMESLO   .byte <(-)
NAMESHI   .byte >(-)

PARENTDIR
	.TEXT ".."
	.FILL 30,0

SID
.if DEBUG = 1
.include "EasySDMenuMock.s"
.endif
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
; In DEBUG mode: SETDIR1/2/3 copies MOCK_DIR1/2/3 data here
; In release mode: PROT_ReadDirectory fills this from SD card
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

; ============================================================
; MOCK DATA — only compiled when DEBUG=1
; ============================================================
; Simulates Arduino HandleReadDirectory wire protocol for VICE
; emulator testing (no SD card needed).
;
; Wire format (must match Arduino CartApi.cpp exactly):
;   Byte 0:    CURPAGEITEMS (number of entries on this page)
;   Byte 1:    PAGECOUNT (total pages, always 1 here)
;   Byte 2+:   64-byte entries:
;              Bytes 0-62:  ASCII filename, null-padded
;              Byte 63:     $04 = directory, $00 = file
;
; Directory flag trick: .enc "screen" + .TEXT "D" = $04
; Filenames are ASCII (.TEXT default), converted to screen
; codes by PRINTASCIIFILENAME at display time.
;
; Mock SD card layout:
;   /                        (MOCK_DIR1 — root)
;   +-- games/               directory
;   +-- giana.prg            PRG program
;   +-- wizball.prg          PRG program
;   +-- sunset.koa           Koala image  -> /PLUGINS/KOAPLUGIN.BIN
;   +-- logo.petg            PETSCII art  -> /PLUGINS/PETGPLUGIN.BIN
;
;   /games/                  (MOCK_DIR2 — level 1)
;   +-- ..                   parent
;   +-- demos/               directory
;   +-- music/               directory
;   +-- bubble.prg           PRG program
;   +-- ocean.koa            Koala image
;   +-- intro.petg           PETSCII art
;
;   /games/demos/            (MOCK_DIR3 — level 2)
;   +-- ..                   parent
;   +-- tools/               directory
;   +-- matrix.prg           PRG program
;   +-- space.koa            Koala image
;   +-- ascii.petg           PETSCII art
;   +-- coder.wav            WAV audio    -> /PLUGINS/WAVPLUGIN.BIN
; ============================================================



; ------------------------------------------------------------
; TAP UI strings (0-terminated)
; ------------------------------------------------------------
.enc "screen"		; .TEXT strings below use C64 screen code encoding (A=$01, etc.)
MSG_TAP_PROMPT
	.TEXT "   TAP: C=CONVERT+RUN  S=SAVE PRG"
	.BYTE 0

MSG_PATH_TOO_LONG
	.TEXT "   PATH TOO LONG"
	.BYTE 0

MSG_TAP_SAVED
	.TEXT "   TAP CONVERT OK: PRG SAVED"
	.BYTE 0

MSG_TAP_UNSUPPORTED
	.TEXT "   UNSUPPORTED TAP (TURBO/NONSTD)"
	.BYTE 0

MSG_TAP_BAD
	.TEXT "   BAD TAP (INVALID/SHORT)"
	.BYTE 0

MSG_TAP_WRITE
	.TEXT "   SD WRITE FAILED"
	.BYTE 0

MSG_TAP_FAIL
	.TEXT "   TAP CONVERT FAILED"
	.BYTE 0

MSG_SD_READ_ERR
	.TEXT "   SD READ ERROR"
	.BYTE 0

MSG_CD_ERROR
	.TEXT "   CD FAILED"
	.BYTE 0

MSG_VICE_DEBUG
	.TEXT "   VICE DEBUG MODE"
	.BYTE 0
.enc "none"		; restore default encoding

; Plugin load address parsing support
PLUGIN_LOAD_ADDR_LO
	.BYTE 0
PLUGIN_LOAD_ADDR_HI
	.BYTE 0
PLUGIN_HEADER
	.FILL 256	; Buffer for reading plugin header (first 256 bytes including load address)

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

; Custom charset data (2KB, CharPad export).
; LOAD_CUSTOM_CHARSET copies this to $3800-$3FFF (VIC bank 0, slot 7) at startup.
; Char $1F = ↓ arrow (replaces original right-arrow).
CUSTOM_CHARSET
	.binary "upper case chars.bin"

	