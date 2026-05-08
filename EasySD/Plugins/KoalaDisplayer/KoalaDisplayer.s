; KOALA displayer plugin for IRQHack64V2
; 15/08/2018 - Istanbul
; I.R.on


.enc "screen"

; DEBUG mode - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Load DEBUG macros BEFORE first use
.include "../../Loader/DebugMacros.s"
.include "../../Loader/APIMacros.s"

; Local diagnostic flag: when 1, VIEWKOALA freezes with $D020 = byte at $2000
; before any display setup. Black border = bitmap data was NOT loaded into
; $2000; any other color = bitmap is in RAM (then set this to 0 and rebuild).
; Exit with SEL button. Independent of the global DEBUG flag.
KOA_VIEW_DEBUG = 0

	*=$C000
	JMP MAIN
	
MAIN	
	JSR INIT		;Clears screen, disables interrupts.	
;	JSR DISPLAYPICTURE	
;-	
;	JMP -

	DELAYFRAMES 100
	PRINTSTATUSANDWAIT INITTEXT, 100	
	DELAYFRAMES 250
	
ALTENTRY

	; PROT_Send uses cycle-counted bit timing. With VIC display ON, badlines
	; (every 8th raster row) steal 40-43 CPU cycles and corrupt the modulation —
	; the Arduino's PROT_StartTalking handshake then misses the I/R/Q identifier
	; and stays in IDLE, so no command is ever decoded. KernalBridge (which works)
	; disables the display BEFORE PROT_StartTalking; we must do the same here.
	JSR PROT_DisableDisplay

	; Start protocol session — MUST be called before any file operations.
	; PROT_EndTalking must be called on ALL exit paths.
	JSR PROT_StartTalking
	#LOADMEDIAPATH MEDIAPATH_BUF	; recover media path from $FF00 shadow

;Lets try to open a file
	PRINTSTATUSANDWAIT OPENINGFILE, 100
	LDX #<MEDIAPATH_BUF
	LDY #>MEDIAPATH_BUF
	JSR PROT_SetNameZ
	BCS ERROR_OPENING_FILE
	LDX #01
	JSR PROT_OpenFile
	BCC OPENINGCONT
	JMP ERROR_OPENING_FILE
OPENINGCONT
	JSR PROT_EnableDisplay

	PRINTSTATUSANDWAIT OPENINGSUCCESS, 200
	;JMP FILEREAD
	PRINTSTATUSANDWAIT READINGFILE, 200

	; Get file info to obtain exact file size
	#SETADDR KOALA_INFO_BUFFER, ZP_IRQ_API_DATA_LO

	JSR PROT_DisableDisplay
	LDY #$00
	JSR PROT_GetInfoForFile
	BCC +                    ; If no error (Carry Clear), continue
	JMP ERRORREADING         ; If error (Carry Set), long jump
+	JSR PROT_EnableDisplay

	; Extract file size from FAT entry (bytes 28-31)
	#EXTRACTFILESIZE KOALA_INFO_BUFFER, ZP_LOADFILE_API_SIZE0

	; Validate KOALA file size and set header skip
	; Expected: 10003 bytes (KOA w/2-byte load addr) or 10001 (raw without header)
	LDA ZP_LOADFILE_API_SIZE2
	ORA ZP_LOADFILE_API_SIZE3
	BEQ +
	JMP ERROR_BADSIZE
+
	LDA ZP_LOADFILE_API_SIZE1
	CMP #>$2713
	BNE CHECK_10001
	LDA ZP_LOADFILE_API_SIZE0
	CMP #<$2713
	BEQ +
	JMP ERROR_BADSIZE
+
	LDA #2
	STA ZP_LOADFILE_API_SKIP_LO
	LDA #0
	STA ZP_LOADFILE_API_SKIP_HI
	JMP SIZE_OK
CHECK_10001
	CMP #>$2711
		BEQ +
		JMP ERROR_BADSIZE
+
	LDA ZP_LOADFILE_API_SIZE0
	CMP #<$2711
		BEQ +
		JMP ERROR_BADSIZE
+
	LDA #0
	STA ZP_LOADFILE_API_SKIP_LO
	STA ZP_LOADFILE_API_SKIP_HI
SIZE_OK
	; Set target address (PICTURE location)
	LDA #<PICTURE
	STA ZP_IRQ_API_DATA_LO
	LDA #>PICTURE
	STA ZP_IRQ_API_DATA_HI

	JSR PROT_DisableDisplay
	LDY #$00
	JSR LoadFileBySize
	BCC +                    ; If no error (Carry Clear), continue
	JMP ERRORREADING         ; If error (Carry Set), long jump
+
	PRINTSTATUSANDWAIT CLOSINGFILE, 250	
	PRINTSTATUSANDWAIT CLOSINGFILE, 250	
	JSR PROT_CloseFile
	BCS ERRORCLOSING
	
CONTINUE	
	PRINTSTATUSANDWAIT FILECLOSED, 200	
	JSR PROT_EndTalking		; End protocol session before showing the picture
	JSR VIEWKOALA
	JMP *
ERRORCLOSING
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT ERRORCLOSINGFILE, 100		
	JMP EXITFAIL
	
EXITFAIL
	JSR PROT_EndTalking		; Stop cartridge communication; return via SEL/reset path
	JMP *
	
	
ERROR_BADSIZE
	; File was opened before this check — close it before exit.
	JSR PROT_CloseFile
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT BADSIZE, 250
	JMP EXITFAIL

ERRORREADING
	; File was opened before this error path — close it before exit.
	JSR PROT_CloseFile
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT READINGFAILED, 200
	JMP EXITFAIL
	
ERROR_OPENING_FILE	
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT OPENINGFILEFAILED, 200		
	JMP EXITFAIL	
	
FILEREAD
	NOP
	JSR PROT_EnableDisplay

	
	JSR VIEWKOALA
	
	CLC		;Signal no error
	RTS
	

INIT		; Input : None, Changed : A
	CLD
	LDA #$93
	JSR CHROUT
	LDA #$00 
	STA $D020
	LDA #$0B
	STA $D021
	JSR INITPC
		
	JSR DISABLEINTERRUPTS		
	JSR KILLCIA
		
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
	
KILLCIA
	;LDA #$00
	;STA ISMUSICPLAYING
	LDY #$7f    ; $7f = %01111111 
    STY $dc0d   ; Turn off CIAs Timer interrupts 
    STY $dd0d   ; Turn off CIAs Timer interrupts 
    LDA $dc0d   ; cancel all CIA-IRQs in queue/unprocessed 
    LDA $dd0d   ; cancel all CIA-IRQs in queue/unprocessed 
	RTS	

DISABLEINTERRUPTS
    LDY #$7f    				; $7f = %01111111 
    STY $dc0d   				; Turn off CIAs Timer interrupts 
    STY $dd0d  				; Turn off CIAs Timer interrupts 
    LDA $dc0d  				; cancel all CIA-IRQs in queue/unprocessed 
    LDA $dd0d   				; cancel all CIA-IRQs in queue/unprocessed 
	
					
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
	LDA #$3B				
	STA $D011	
	RTS

PICTURE = $2000
 BITMAP = PICTURE
 VIDEO = PICTURE+$1f40
 COLOR = PICTURE+$2328
 BACKGROUND = PICTURE+$2710	
 SCREENRAM = $0400
	
	
VIEWKOALA
	JSR FORCEIO			; Ensure I/O visible for VIC registers

.if KOA_VIEW_DEBUG = 1
	; Diagnostic: freeze on $D020 = first bitmap byte at $2000.
	; Black border = bitmap NOT loaded; any color = data is in RAM.
	; Press SEL to exit. Set KOA_VIEW_DEBUG=0 + rebuild after testing.
KOA_DBG_HANG:
	LDA $2000
	STA $D020
	JMP KOA_DBG_HANG
.endif

	lda #$0b			; Keep display off while video/color data is moved
	sta $d011
	lda #$00
	sta $d020			; Border Color

	; Transfer screen matrix (1000 bytes) and color RAM (1000 bytes).
	; Source blocks are exactly 1000 bytes ($3E8); the last 256-byte stride
	; uses +$2E8 so it covers offsets 744..999 (matches the original
	; IRQHack64 KoalaDisplayer pattern; +$300 would overrun into adjacent data).
	ldx #$00
LOOPTRANSFER
	lda VIDEO,x
	sta SCREENRAM,x
	lda VIDEO+$100,x
	sta SCREENRAM+$100,x
	lda VIDEO+$200,x
	sta SCREENRAM+$200,x
	lda VIDEO+$2e8,x
	sta SCREENRAM+$2e8,x
	lda COLOR,x
	sta $d800,x
	lda COLOR+$100,x
	sta $d900,x
	lda COLOR+$200,x
	sta $da00,x
	lda COLOR+$2e8,x
	sta $dae8,x
	inx
	bne LOOPTRANSFER

	lda BACKGROUND
	sta $d021			; Screen Color

	; VIC bank 0 ($0000-$3FFF): bitmap $2000, screen matrix $0400.
	; This avoids loading Koala payload into $8000-$9FFF while EasySD ROML is active.
	; DDR_A defaults to $3F after KERNAL boot (PA0/PA1 already output) — no need to touch it.
	LDA $DD00
	AND #$FC
	ORA #$03
	STA $DD00

	; $D018 = $18: video matrix at $0400, bitmap at $2000 (within VIC bank 0).
	lda #$18
	sta $d018
	; Multicolor mode on.
	lda #$d8
	sta $d016
	; Bitmap mode on, display enable.
	lda #$3b
	sta $d011

	RTS



;------------------------------------------------------------
; Plugin local strings
;------------------------------------------------------------
BADSIZE
	.text "BAD KOALA SIZE",0

FORCEIO
	LDA #PP_CONFIG_DEFAULT		; Ensure I/O and KERNAL are visible
	STA $01
	RTS

.include "../../Loader/CartLibStream.s"
.include "../../Loader/DebugStrings.s"

;-----------------------------------------------
; Plugin-specific label aliases for compatibility
;-----------------------------------------------
INITTEXT = KOALA_HEADER
SENDSTARTTALKING = STARTTALKING
STARTEDTALKING = TALKINGSTARTED
OPENINGFILEFAILED = OPENINGFAILED
FILECLOSED = CLOSINGSUCCESS
ERRORCLOSINGFILE = CLOSINGFAILED

KOALA_INFO_BUFFER:
	.FILL 256

; Local copy of the media file path recovered from FILE_PATH_SHADOW ($FF00).
MEDIAPATH_BUF
	.FILL FILE_PATH_SHADOW_MAX, 0

READBUFFER
