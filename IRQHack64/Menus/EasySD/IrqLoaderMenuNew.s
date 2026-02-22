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

; --- Menu Zero Page Variables (User range $FB-$FE) ---
NAMELOW          = $FB
NAMEHIGH         = $FC
COLLOW           = $FD
COLHIGH          = $FE

; --- Menu RAM Variables ---
PATHBUFFER       = $033C ; Cassette buffer
FILENAMESHADOW   = $0200 
DIRSTACKTEMP     = $FD00 

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




	*=$080E
	LDX #$FB
	TXS
;	LDA MODULATION_ADDRESS
;	DELAYFRAMES	10
;	LDA #PP_CONFIG_RAM_ON_BASIC
;	STA PROCESSOR_PORT
	JSR PREINIT

.if DEBUG = 1
	JSR DEBUG_Init		; Initialize DEBUG dump area ($CF00)
.endif

	JSR DISPLAYPETGRAPHICS
	DELAYFRAMES 75

	JSR IRQ_DisableDisplay	
	JSR DISPLAYSCREENGRAPHICS
	LDA #$40
	STA $028A		; Disable all key repeat (RPTFLG)
	;JSR POSTINIT		;Clears screen, disables interrupts, copies sid to $C000 and inits it.
	;JMP INPUT_GET
.if DEBUG = 0 
	JSR IRQ_StartTalking
.else
	NOP
	NOP
	NOP
.endif		
	LDA #<DIRLOAD
	STA ZP_IRQ_DATA_LOW
	LDA #>DIRLOAD
	STA ZP_IRQ_DATA_HIGH
	LDA #$03		;Max 256*3 bytes of data
	STA ZP_IRQ_DATA_LENGTH	
	LDA #<(DIRREAD-1)
	STA ZP_IRQ_CALLBACK_LO
	LDA #>(DIRREAD-1)
	STA ZP_IRQ_CALLBACK_HI	

	TSX
	STX $C000
	
	LDY #$00		
	LDX #MAXDIRITEMS
	LDA CURPAGEINDEX
	
.if DEBUG = 0 
	JSR IRQ_ReadDirectory	
.else
	JSR SETDIR1
	JSR DIRREAD
.endif		
		
	; Do error handling if directory can't be read (carry is set)

		
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
	JSR GETCURRENTROW
	JSR CLEARARROW
	TXA
	BNE NORMALUP
	LDX CURPAGEITEMS
NORMALUP	
	DEX
	JSR SETCURRENTROWHEAD 	
	JSR SETARROW
	JMP INPUT_GET

DOWN
	LDX #COMMANDENTERMASK
	STX COMMANDBYTE	
	JSR GETCURRENTROW	
	JSR CLEARARROW
	INX
	CPX CURPAGEITEMS
	BNE ROLLINGDOWN
	LDX #$00
ROLLINGDOWN	
	JSR SETCURRENTROWHEAD 
	JSR SETARROW
	JMP INPUT_GET	

; Below routine fills the COMMANDBYTE to the relevant action taken by the user.
; With the start of the ENTER control byte is sent to micro by modulating raster interrupts


NEXTPAGE
	LDX CURPAGEINDEX
	INX
	CPX PAGECOUNT
	BCC EXECNEXT	; FIX: Use standard BCC (Branch if Carry Clear) instead of BLT
	JMP INPUT_GET
EXECNEXT
	INC CURPAGEINDEX	
	LDX #COMMANDNEXTPAGE
	STX COMMANDBYTE
	JSR IRQ_DisableDisplay
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
	JSR IRQ_DisableDisplay	
	JMP DOREADDIRECTORY
	
ENTER  	  

	JSR IRQ_DisableDisplay
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
	; Prevent DIRLEVEL underflow
	LDA DIRLEVEL
	BEQ +
	DEC DIRLEVEL
+
.endif
	JSR POPDIRNAME
	JSR GOBACK
	;JMP NEWCONTENT
	JMP DOREADDIRECTORY
	
NOPREV	
	JSR PUSHDIRNAME
	
	; Enter directory
	JMP ENTERDIR
; ------------------------------------------------------------
; IRQ_SetNameZ
;   Input : X=lo, Y=hi pointer to 0-terminated string
;   Output: calls IRQ_SetName with computed length (max PATH_MAX)
;   Carry : set on error (unterminated/too long), clear on success
; ------------------------------------------------------------
IRQ_SetNameZ
	STX $06
	STY $07
	LDY #0
_isnz_loop
	LDA ($06), Y
	BEQ _isnz_done
	INY
	CPY #PATH_MAX
	BNE _isnz_loop
	SEC
	RTS
_isnz_done
	TYA			; A = length
	PHA
	LDX $06
	LDY $07
	PLA
	JSR IRQ_SetName
	CLC
	RTS


; ------------------------------------------------------------
; BuildAbsolutePathFromPtr
;   Input : $06/$07 = pointer to selected basename (0-terminated)
;   Output: PATHBUFFER filled with "/dir1/dir2/file.ext" (0-term)
;           A = length (excluding terminator)
;           C = 0 success, C = 1 path too long
;   Uses  : A,X,Y,$08,$09,$0A
; Notes  : Uses CURRENTDIRINDEX + DIRSTACK entries as path stack.
; ------------------------------------------------------------
BuildAbsolutePathFromPtr
	; start with '/'
	LDX #0
	LDA #$2F			; '/'
	STA PATHBUFFER, X
	INX
	STX PATHLEN

	LDX #0			; dir index
_bap_dir_loop
	CPX CURRENTDIRINDEX
	BEQ _bap_copy_file

	; $08/$09 = pointer to DIRSTACK[X]
	LDA DIRNAMESLO, X
	STA $08
	LDA DIRNAMESHI, X
	STA $09
	STX $0A			; save dir index

	LDY #0
_bap_copy_dir
	LDX PATHLEN
	LDA ($08), Y
	BEQ _bap_end_dir
	CPX #PATH_MAX
	BCS _bap_too_long
	STA PATHBUFFER, X
	INX
	STX PATHLEN
	INY
	BNE _bap_copy_dir

_bap_end_dir
	LDX PATHLEN
	CPX #PATH_MAX
	BCS _bap_too_long
	LDA #$2F
	STA PATHBUFFER, X
	INX
	STX PATHLEN

	LDX $0A
	INX
	JMP _bap_dir_loop

_bap_copy_file
	LDY #0
_bap_copy_file_loop
	LDX PATHLEN
	LDA ($06), Y
	BEQ _bap_finish
	CPX #PATH_MAX
	BCS _bap_too_long
	STA PATHBUFFER, X
	INX
	STX PATHLEN
	INY
	BNE _bap_copy_file_loop

_bap_finish
	LDX PATHLEN
	LDA #0
	STA PATHBUFFER, X
	TXA			; length in A
	CLC
	RTS

_bap_too_long
	SEC
	RTS


ENTERDIR
.if DEBUG = 0
	JSR IRQ_ChangeDirectory
	BCS CHANGEDIRFAIL	
.else
	INC DIRLEVEL
	; DEBUG mock supports DIRLEVEL 0..2 only (MOCK_DIR1..DIR3)
	LDA DIRLEVEL
	CMP #3
	BCC +
	LDA #2
	STA DIRLEVEL
+

.endif	

	
	DELAYFRAMES 2
	; Read directory
DOREADDIRECTORY	
	LDA #<DIRLOAD
	STA ZP_IRQ_DATA_LOW
	LDA #>DIRLOAD
	STA ZP_IRQ_DATA_HIGH
	LDA #$03		;Max 256*3 bytes of data
	STA ZP_IRQ_DATA_LENGTH	
	
	LDY #$00		
	LDX #20			;Max 20 directory items
	LDA CURPAGEINDEX
.if DEBUG = 0
	JSR IRQ_ReadDirectoryNC
.else
	LDA DIRLEVEL
	CMP #00
	BNE +
	JSR SETDIR1
	JMP OUTDIRSET
+	
	CMP #01
	BNE +
	JSR SETDIR2
	JMP OUTDIRSET	
+	
	CMP #02
	BNE +
	JSR SETDIR3
+
OUTDIRSET
.endif
	
	JMP NEWCONTENT
	
	
CHANGEDIRFAIL
	LDA #$07
	STA BORDER
	JMP *
	; Do an error text
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
	JSR IRQ_SetNameZ			
	
	LDX #01		; Flags=read
	JSR IRQ_OpenFile
	BCC BINPLUGINEXISTS
	
	DELAYFRAMES 1
	
	JSR BUILDPLUGINNAME_PRG
	LDX #<PLUGINNAME
	LDY #>PLUGINNAME
	JSR IRQ_SetNameZ			
	LDX #01		; Flags=read
	JSR IRQ_OpenFile
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
		;  3) Load exact payload size using IRQ_GetInfoForFile + LoadFileBySize
		;
		; Algorithm:
		;   - Read first 256 bytes to PLUGIN_HEADER to get load address
		;   - Query file size, copy size into IRQ_FILE_SIZE_* ($80-$83)
		;   - Seek to offset 2 (skip PRG header) and load full payload to load address
		; ------------------------------------------------------------

		; Step 1: Read first page (contains PRG load address)
	LDA #<PLUGIN_HEADER
	STA ZP_IRQ_DATA_LOW
	LDA #>PLUGIN_HEADER
	STA ZP_IRQ_DATA_HIGH
	LDA #1			; Read 1 page (256 bytes) for header
	STA ZP_IRQ_DATA_LENGTH

	JSR IRQ_DisableDisplay

	; Enable cartridge ROM access before reading
	CART_ROM_ENABLE

		LDY #$00
	JSR IRQ_ReadFileNoCallback

	; Restore normal configuration
	CART_ROM_RESTORE

		; Step 2: Parse PRG load address (first 2 bytes)
	LDA PLUGIN_HEADER
	STA PLUGIN_LOAD_ADDR_LO
		STA ZP_IRQ_DATA_LOW		; Target load address for payload
	LDA PLUGIN_HEADER+1
	STA PLUGIN_LOAD_ADDR_HI
	STA ZP_IRQ_DATA_HIGH

		; Step 3: Get file size (FAT directory entry) so we can load exact bytes
		; Reuse PLUGIN_HEADER buffer to receive the 256-byte info block.
		LDA #<PLUGIN_HEADER
		STA ZP_IRQ_DATA_LOW
		LDA #>PLUGIN_HEADER
		STA ZP_IRQ_DATA_HIGH
		LDY #$00
		CART_ROM_ENABLE
		JSR IRQ_GetInfoForFile
		CART_ROM_RESTORE
		BCS BINPLUGIN_LOAD_ERROR_INFO	; If GetInfo failed, abort

		; Extract 32-bit file size (offset 28..31 in first 32 bytes of dir entry)
		LDA PLUGIN_HEADER+28
		STA ZP_LF_SIZE0		; $80
		LDA PLUGIN_HEADER+29
		STA ZP_LF_SIZE1		; $81
		LDA PLUGIN_HEADER+30
		STA ZP_LF_SIZE2		; $82
		LDA PLUGIN_HEADER+31
		STA ZP_LF_SIZE3		; $83

		; Step 4: Load full PRG payload (skip 2-byte header) to PLUGIN_LOAD_ADDR
		LDA #$02
		STA ZP_LF_SKIP_LO		; $84
		LDA #$00
		STA ZP_LF_SKIP_HI		; $85

		CART_ROM_ENABLE
		JSR LoadFileBySize
		CART_ROM_RESTORE
		BCS BINPLUGIN_LOAD_ERROR_LOAD	; If load failed, abort

	
; ------------------------------------------------------------
; BIN Plugin load error handlers
; ------------------------------------------------------------
BINPLUGIN_LOAD_ERROR_INFO:
.if DEBUG = 1
	LDA #$02				; Error code 2 = IRQ_GetInfoForFile failed
	JSR DEBUG_SetError
	JSR DEBUG_Break
.endif
	JSR IRQ_CloseFile
	JSR IRQ_EnableDisplay
	JMP INPUT_GET

BINPLUGIN_LOAD_ERROR_LOAD:
.if DEBUG = 1
	LDA #$03				; Error code 3 = payload load failed (LoadFileBySize sets 1 internally too)
	JSR DEBUG_SetError
	JSR DEBUG_Break
.endif
	JSR IRQ_CloseFile
	JSR IRQ_EnableDisplay
	JMP INPUT_GET

LDA #1
	STA $D020

	;JSR IRQ_EnableDisplay

PETGLPLUGINREAD

	DELAYFRAMES	1
	JSR IRQ_CloseFile

	JSR IRQ_EnableDisplay

	JSR GETCURRENTROW

	JSR PrepareFileNameParameter

	; Jump to plugin entry point (indirect jump using load address)
	JMP (PLUGIN_LOAD_ADDR_LO)	

		
PRGPLUGINEXISTS	
	DELAYFRAMES	1	
	JSR IRQ_CloseFile	
	
	JSR GETCURRENTROW	
	JSR PrepareFileNameParameter

	JSR IRQ_InvokeWithName

	JMP *

PROGRAM	
	LDA #$02 
	STA BORDER
	JSR GETCURRENTROW	
	;Setting name of the file
	JSR SETFILENAME	
.if DEBUG = 0
	; If it's a .tap, offer choice: Convert+Run (default) or Save only.
	JSR IS_TAP_SELECTED
	BEQ +
	; --- TAP path ---
	JSR TAP_CHOICE
	; X now holds flags for IRQ_InvokeWithName (bit0=autorun)
	JSR IRQ_InvokeWithName
	BCC TAP_INVOKE_OK
	; Error: A holds error code
	JSR TAP_SHOW_ERROR
	JSR IRQ_EnableDisplay
	JMP INPUT_GET
TAP_INVOKE_OK
	; If save-only (bit0=0), stay in menu and show success.
	TXA
	AND #$01
	BNE TAP_AUTORUN
	LDX #<MSG_TAP_SAVED
	LDY #>MSG_TAP_SAVED
	JSR STATUS_LINE
	JSR IRQ_EnableDisplay
	JMP INPUT_GET
TAP_AUTORUN
	; Auto-run path: the micro will reset C64 and load the converted PRG.
	JMP *

	; --- Non-TAP default path ---
+	;Invoking with name
	LDX #$01		; flags: autorun
	JSR IRQ_InvokeWithName
	BCC SUCCEEDINVOKE
	JSR IRQ_EnableDisplay
SUCCEEDINVOKE
	JMP *
.else
	; --- DEBUG: Mock PRG load + execute ---
	; Mark that PROGRAM path was reached
	LDA #$01
	STA DEBUG_PRG_REACHED

	; Copy mock PRG code to $C000
	LDX #0
-	LDA MOCK_PRG_CODE, X
	STA $C000, X
	INX
	CPX #MOCK_PRG_CODE_SIZE
	BNE -

	; Patch JMP target with actual INPUT_GET address
	LDA #<INPUT_GET
	STA $C000 + MOCK_PRG_JMP_OFFSET
	LDA #>INPUT_GET
	STA $C000 + MOCK_PRG_JMP_OFFSET + 1

	JSR IRQ_EnableDisplay
	JMP $C000		; execute mock PRG
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


; Waits for user choice. Returns X flags for IRQ_InvokeWithName.
; Default: Convert+Run (X=$01). Save-only: X=$00.
TAP_CHOICE
	LDX #<MSG_TAP_PROMPT
	LDY #>MSG_TAP_PROMPT
	JSR STATUS_LINE
	JSR IRQ_EnableDisplay
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


; A contains error code from IRQ_InvokeWithName (carry set)
TAP_SHOW_ERROR
	CMP #$12			; TAP_UNSUPPORTED
	BEQ _uns
	CMP #$13			; TAP_BAD_TAP
	BEQ _bad
	CMP #$14			; TAP_WRITE_FAILED
	BEQ _wr
	LDX #<MSG_TAP_FAIL
	LDY #>MSG_TAP_FAIL
	JMP STATUS_LINE
_uns
	LDX #<MSG_TAP_UNSUPPORTED
	LDY #>MSG_TAP_UNSUPPORTED
	JMP STATUS_LINE
_bad
	LDX #<MSG_TAP_BAD
	LDY #>MSG_TAP_BAD
	JMP STATUS_LINE
_wr
	LDX #<MSG_TAP_WRITE
	LDY #>MSG_TAP_WRITE
	JMP STATUS_LINE


; Prints a 0-terminated string (X=lo, Y=hi) to bottom status line (row 24)
STATUS_LINE
	STX $06
	STY $07
	LDY #$00
_copy
	LDA ($06), Y
	BEQ _pad
	STA $07C0, Y
	INY
	CPY #$28			; 40
	BNE _copy
	RTS
_pad
	LDA #$20
_padloop
	STA $07C0, Y
	INY
	CPY #$28
	BNE _padloop
	RTS
	
SPECIALCMD		

	; INVOKE PLUGIN

	
GOBACK
	; Go to root.. Traverse stack starting from root... Change directories
	; Change directory to root
	LDA #>PARENTDIR
	TAY
	LDA #<PARENTDIR
	TAX
	JSR IRQ_SetNameZ			
.if DEBUG = 0	
	JSR IRQ_ChangeDirectory
.else
	LDA #00
	STA	DIRLEVEL
.endif
	DELAYFRAMES 2
	
	; From 0 to CURRENTDIRINDEX change dirs (current dir will be popped of stack beforehand)
	LDY CURRENTDIRINDEX
	BEQ _RestoreLoopDone
	LDY #00
-		
	TYA
	PHA
	LDA DIRNAMESLO, Y
	TAX
	LDA DIRNAMESHI, Y
	TAY
	JSR IRQ_SetNameZ
.if DEBUG = 0
	JSR IRQ_ChangeDirectory
+	; Alignment label for consistent forward jump target
.else
+	; Alignment label for consistent forward jump target
	INC DIRLEVEL
	; DEBUG mock supports DIRLEVEL 0..2 only (MOCK_DIR1..DIR3)
	LDA DIRLEVEL
	CMP #3
	BCC ++	; Double forward jump to skip clamp
	LDA #2
	STA DIRLEVEL
+	; Clamp skip target
.endif
	DELAYFRAMES 2
	PLA
	TAY
	INY
	CPY CURRENTDIRINDEX
	BNE -

_RestoreLoopDone
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
	INC BORDER

	JSR IRQ_EnableDisplay	
	JSR GETCURRENTROW	
	JSR CLEARARROW	
	JSR PRINTPAGE
	LDX #00
	JSR SETCURRENTROWHEAD 
	JSR SETARROW

	CLI
	JMP INPUT_GET
  	
	RTS	

DIRREAD		
;	LDA #$02
;	STA BORDER

;	DELAYFRAMES 10
	JSR IRQ_EnableDisplay	
		
	; Title is part of the PETMATE frame, no separate print needed


	;Call it elsewhere
	JSR PRINTPAGE		;Prints the initial filenames that's added to the program by the micro.
	LDX #$00		;Puts the selector 
	JSR SETCURRENTROWHEAD	;to the first entry in the
	JSR SETARROW		;list
	CLC
	RTS

.if DEBUG = 1
; ============================================================
; MOCK CODE — only compiled when DEBUG=1
; ============================================================
; These routines replace Arduino SD card communication with
; hardcoded directory data (MOCK_DIR1/2/3) for VICE emulator
; testing. See also: MOCK DATA section near end of file.
;
; Copy uses X register (forward) — Y (backward) corrupts data.
; ============================================================

SETDIR1
	LDA #$02        ; BORDER = RED (visual indicator)
	STA $D020
	LDX #$00
-
	LDA MOCK_DIR1, X
	STA DIRLOAD, X
	INX
	CPX #(MOCK_DIR2-MOCK_DIR1)
	BNE -
	LDA #$05        ; BORDER = GREEN (visual indicator)
	STA $D020
	RTS

SETDIR2
	LDX #$00
-
	LDA MOCK_DIR2, X
	STA DIRLOAD, X
	INX
	CPX #(MOCK_DIR3-MOCK_DIR2)
	BNE -
	RTS

SETDIR3
	LDX #$00
-
	LDA MOCK_DIR3, X
	STA DIRLOAD, X
	INX
	CPX #(MOCK_DIR3_END-MOCK_DIR3)
	BNE -
	RTS
.endif

	
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
	; DEBUG: Set $06/$07 and dump filename
	LDA NAMESLO, X
	STA $06
	LDA NAMESHI, X
	STA $07
	JSR DEBUG_DumpFilename
.endif

	; $06/$07 -> selected basename
	LDA NAMESLO, X
	STA $06
	LDA NAMESHI, X
	STA $07

	JSR BuildAbsolutePathFromPtr
	BCS _sf_path_too_long

	; A = length, PATHBUFFER contains 0-terminated absolute path
	PHA			; save length
	LDX #<PATHBUFFER
	LDY #>PATHBUFFER
	PLA			; A = length
	JSR IRQ_SetName
	RTS

_sf_path_too_long
	LDX #<MSG_PATH_TOO_LONG
	LDY #>MSG_PATH_TOO_LONG
	JSR STATUS_LINE
	SEC
	RTS

ISDIRECTORY
	LDA NAMESLO, X
	STA NAMELOW
	LDA NAMESHI, X
	STA NAMEHIGH
	LDY #31
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
	; Reverse + color only non-space chars (cols 4-35)
	LDY #$02
_SETARR_LOOP
	LDA (COLLOW),Y		; Read screen code
	CMP #$20		; Space?
	BEQ _SETARR_NEXT	; Skip spaces
	ORA #$80		; Reverse
	STA (COLLOW),Y		; Write to screen RAM
	LDA NAMEHIGH		; Switch to color RAM
	STA COLHIGH
	LDA #$01		; White
	STA (COLLOW),Y
	LDA NAMELOW		; Switch back to screen RAM
	STA COLHIGH
_SETARR_NEXT
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
	LDY #$00
	CPX #$00		; First item?
	BEQ _CLRARR_FIRST
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
_CLRARR_FIRST
	; First: reversed space + horizontal line
	LDA #$A0
	STA (COLLOW),Y		; col 2
	INY
	LDA #$40
	STA (COLLOW),Y		; col 3
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
	CMP #$61            ; >= 'a'?
	BCC WRITECHAR_A     ; No → numbers/symbols/uppercase, use as-is
	CMP #$7B            ; <= 'z'?
	BCS WRITECHAR_A     ; No → use as-is
	SEC
	SBC #$20            ; Lowercase $61-$7A → uppercase $41-$5A
WRITECHAR_A
	STA (COLLOW), Y     ; Write to screen memory
	INY
	CPY #$20            ; Print 32 characters (full line)
	BNE FILENAMEPRINT_A
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
	LDA #00
	STA CURRENTDIRINDEX  
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
	ADC #$20
	STA NAMELOW
	BCC NEXTFILE
	INC NAMEHIGH
NEXTFILE
	JMP SETCOL	
FINISH
	CPX #$14
	BEQ ACTUALFINISH
	JSR SETCURRENTROW
	JSR CLEARLINE
	INX 
	CLV
	BVC FINISH
	
ACTUALFINISH
	JSR DRAWDECORATIONS
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
	CPX #$14		; 20 = max items
	BEQ _DDEC_DONE
	JSR SETCURRENTROWHEAD	; COLLOW = col 2 of row X
	CPX CURPAGEITEMS
	BCS _DDEC_EMPTY		; >= item count -> empty row
	; Active item - determine first/last or middle
	LDY #$00
	CPX #$00		; First item?
	BEQ _DDEC_FIRST
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
_DDEC_FIRST
	; First: reversed space + horizontal line, white
	LDA #$A0
	STA (COLLOW),Y		; col 2
	INY
	LDA #$40
	STA (COLLOW),Y		; col 3 = horizontal line
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

PrepareFileNameParameter:
	; We have current row in X
	LDA NAMESLO, X
	STA $06
	LDA NAMESHI, X
	STA $07

	; Build absolute path into PATHBUFFER ($033C)
	JSR BuildAbsolutePathFromPtr
	BCS PATH_TOO_LONG_HANDLER

	; Copy full buffer to shadow (PATHBUF_SIZE bytes)
	LDY #0
COPY_PATH_TO_SHADOW
	LDA PATHBUFFER, Y
	STA FILENAMESHADOW, Y
	INY
	CPY #PATHBUF_SIZE
	BNE COPY_PATH_TO_SHADOW

.if DEBUG = 1
	JSR DEBUG_DumpFilename		; optional
.endif

	LDA CURRENTDIRINDEX
	STA CURRENTDIRINDEXSHADOW

	; Copy dirstack to temp (320 bytes)
	; Copy first page (256 bytes)
	LDY #0
-	
	LDA DIRSTACK, Y
	STA DIRSTACKTEMP, Y
	INY
	BNE - 

	; Copy remaining 64 bytes of the second page
	LDY #0
-	
	LDA DIRSTACK+$100, Y
	STA DIRSTACKTEMP+$100, Y
	INY
	CPY #64
	BNE -

	RTS

PATH_TOO_LONG_HANDLER
	LDX #<MSG_PATH_TOO_LONG
	LDY #>MSG_PATH_TOO_LONG
	JSR STATUS_LINE
	RTS

PUSHDIRNAME:	
	; We have current row in X
	LDA NAMESLO, X	
	STA $06
	LDA NAMESHI, X
	STA $07	
	
COPYDIRNAME	
	LDX CURRENTDIRINDEX
	LDA DIRNAMESLO, X	
	STA $08
	LDA DIRNAMESHI, X
	STA $09	

	
	LDY #0
-	
	LDA ($06) , Y
	STA ($08) , Y
	STA CASSETTEBUFFER, Y
	STA FILENAMESHADOW, Y
	INY
	CPY #MAXFILENAMELENGTH
	BNE -
	
	INX
	STX CURRENTDIRINDEX
	RTS		

POPDIRNAME:		
	LDY CURRENTDIRINDEX
	BEQ +
	DEY 
	STY CURRENTDIRINDEX
+	
	RTS
	
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
	; Switch to lowercase/uppercase charset for PETMATE frame
	LDA $D018
	ORA #$02
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
CURRENTDIRINDEX	.BYTE 0
CURRENTDIRINDEXSHADOW	.BYTE 0
PATHLEN	.BYTE 0
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
	
MAXFILENAMELENGTH = 32	
MAXDIRITEMS = 20	
-       = GAMELIST + range(0, MAXDIRITEMS * MAXFILENAMELENGTH, MAXFILENAMELENGTH)
NAMESLO   .byte <(-)
NAMESHI   .byte >(-)

DIRECTORIESMAXDEPTH	= 10	

-       = DIRSTACK + range(0, MAXFILENAMELENGTH * DIRECTORIESMAXDEPTH, MAXFILENAMELENGTH)
DIRNAMESLO   .byte <(-)
DIRNAMESHI   .byte >(-)

	

PARENTDIR
	.TEXT ".."
	.FILL 30,0

; Library on the arduino doesn't support opening parent directories, so we need to go to root and then 
; traverse the path to the current path's parent.
DIRSTACK
	.FILL 32 * DIRECTORIESMAXDEPTH

	
;	*=$0E00

SID	
; 	.binary "SidFile.bin"

;.include "PatternMatch.s"
.include "../../Loader/CartLibStream.s"
;.include "../../Loader/FakeCartLib.s"
;.include "../../Loader/FakeCartLibHi.s"
.include "Filename.s"		
	

; File name storage area
;	*=$1BEF
;	.BYTE 64
;DATAAREA 

;CURPAGEITEMS	= $1BFE
;PAGECOUNT	= $1BFF
;CURPAGEINDEX	= $1BF2
;GAMELIST	 = $1C00
;IRQBUFFER 	 = $1F00

;DIRLOAD = GAMELIST - 2



;	.BYTE 64
;DATAAREA 

; character data
;*=$2800
PRGSCREENDATA
	; Generated from PETMATE menu.asm by build.py (lowercase/uppercase charset)
	.binary "menu.bin"

CURPAGEINDEX	.BYTE 0

; Directory metadata and entries buffer
; IMPORTANT: CURPAGEITEMS and PAGECOUNT must be immediately before GAMELIST
; because DIRLOAD = GAMELIST - 2 points to CURPAGEITEMS
CURPAGEITEMS	.BYTE 5
PAGECOUNT		.BYTE 1
GAMELIST
DIRLOAD = GAMELIST - 2
; Reserve space for 20 directory entries (20 * 32 bytes = 640 bytes)
; In DEBUG mode: SETDIR1/2/3 copies MOCK_DIR1/2/3 data here
; In release mode: IRQ_ReadDirectory fills this from SD card
	.FILL (20 * 32), 0


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
;   Byte 2+:   32-byte entries:
;              Bytes 0-30:  ASCII filename, null-padded
;              Byte 31:     $04 = directory, $00 = file
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

.if DEBUG = 1

DIRLEVEL	.BYTE 0

; --- Root directory (DIRLEVEL=0) — 5 entries -----------------
MOCK_DIR1
	.BYTE 5             ; CURPAGEITEMS
	.BYTE 1             ; PAGECOUNT
	;-- entry 0: "games" (directory) --
	.TEXT "games"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 1: "giana.prg" (PRG file) --
	.TEXT "giana.prg"
	.FILL 23, 0         ; byte 31 = $00 = file
	;-- entry 2: "wizball.prg" (PRG file) --
	.TEXT "wizball.prg"
	.FILL 21, 0
	;-- entry 3: "sunset.koa" (Koala image) --
	.TEXT "sunset.koa"
	.FILL 22, 0
	;-- entry 4: "logo.petg" (PETSCII art) --
	.TEXT "logo.petg"
	.FILL 23, 0

; --- /games/ (DIRLEVEL=1) — 6 entries -----------------------
MOCK_DIR2
	.BYTE 6             ; CURPAGEITEMS
	.BYTE 1             ; PAGECOUNT
	;-- entry 0: ".." (parent directory) --
	.TEXT ".."
	.FILL 29, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 1: "demos" (directory) --
	.TEXT "demos"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 2: "music" (directory) --
	.TEXT "music"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 3: "bubble.prg" (PRG file) --
	.TEXT "bubble.prg"
	.FILL 22, 0
	;-- entry 4: "ocean.koa" (Koala image) --
	.TEXT "ocean.koa"
	.FILL 23, 0
	;-- entry 5: "intro.petg" (PETSCII art) --
	.TEXT "intro.petg"
	.FILL 22, 0

; --- /games/demos/ (DIRLEVEL=2) — 6 entries -----------------
MOCK_DIR3
	.BYTE 6             ; CURPAGEITEMS
	.BYTE 1             ; PAGECOUNT
	;-- entry 0: ".." (parent directory) --
	.TEXT ".."
	.FILL 29, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 1: "tools" (directory) --
	.TEXT "tools"
	.FILL 26, 0
.enc "screen"
	.TEXT "D"           ; $04 = directory
.enc "none"
	;-- entry 2: "matrix.prg" (PRG file) --
	.TEXT "matrix.prg"
	.FILL 22, 0
	;-- entry 3: "space.koa" (Koala image) --
	.TEXT "space.koa"
	.FILL 23, 0
	;-- entry 4: "ascii.petg" (PETSCII art) --
	.TEXT "ascii.petg"
	.FILL 22, 0
	;-- entry 5: "coder.wav" (WAV audio) --
	.TEXT "coder.wav"
	.FILL 23, 0

; --- Mock PRG program (loaded to $C000, returns to menu) ---
MOCK_PRG_CODE
	LDA #$42		; sentinel value 1
	STA DEBUG_PRG_EXECUTED	; $CF51
	LDA #$DE		; sentinel value 2
	STA DEBUG_PRG_SENTINEL	; $CF52
	JMP $0000		; placeholder — patched to INPUT_GET at runtime
MOCK_PRG_CODE_END
MOCK_PRG_CODE_SIZE = MOCK_PRG_CODE_END - MOCK_PRG_CODE
MOCK_PRG_JMP_OFFSET = MOCK_PRG_CODE_END - MOCK_PRG_CODE - 2

.endif

MOCK_DIR3_END


; ------------------------------------------------------------
; TAP UI strings (0-terminated)
; ------------------------------------------------------------
MSG_TAP_PROMPT
	.TEXT "TAP: C=CONVERT+RUN  S=SAVE PRG"
	.BYTE 0

MSG_PATH_TOO_LONG
	.TEXT "PATH TOO LONG"
	.BYTE 0

MSG_TAP_SAVED
	.TEXT "TAP CONVERT OK: PRG SAVED"
	.BYTE 0

MSG_TAP_UNSUPPORTED
	.TEXT "UNSUPPORTED TAP (TURBO/NONSTD)"
	.BYTE 0

MSG_TAP_BAD
	.TEXT "BAD TAP (INVALID/SHORT)"
	.BYTE 0

MSG_TAP_WRITE
	.TEXT "SD WRITE FAILED"
	.BYTE 0

MSG_TAP_FAIL
	.TEXT "TAP CONVERT FAILED"
	.BYTE 0

; Plugin load address parsing support
PLUGIN_LOAD_ADDR_LO
	.BYTE 0
PLUGIN_LOAD_ADDR_HI
	.BYTE 0
PLUGIN_HEADER
	.FILL 256	; Buffer for reading plugin header (first 256 bytes including load address)

	