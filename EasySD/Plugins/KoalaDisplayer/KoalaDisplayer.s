; KOALA displayer plugin for IRQHack64V2
; 15/08/2018 - Istanbul
; I.R.on


.enc "screen"

; DEBUG mode - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Load DEBUG macros BEFORE first use
.include "../../Loader/DebugMacros.s"

	*=$C000
	JMP MAIN
	
MAIN	
	JSR SAVESTATE		; Save VIC/$01 state for clean return
	JSR INIT		;Clears screen, disables interrupts.	
;	JSR DISPLAYPICTURE	
;-	
;	JMP -

	DELAYFRAMES 100
	PRINTSTATUSANDWAIT INITTEXT, 100	
	DELAYFRAMES 250
	
ALTENTRY	

;Lets try to open a file
	PRINTSTATUSANDWAIT OPENINGFILE, 100
	JSR PROT_DisableDisplay		
	LDX #<FILE_PATH_BUF
	LDY #>FILE_PATH_BUF
	LDA #31
	JSR PROT_SetName
	LDX #01		; Flags=read
	JSR PROT_OpenFile
	BCC OPENINGCONT
	JMP ERROR_OPENING_FILE
OPENINGCONT
	JSR PROT_EnableDisplay

	PRINTSTATUSANDWAIT OPENINGSUCCESS, 200
	;JMP FILEREAD
	PRINTSTATUSANDWAIT READINGFILE, 200

	; Get file info to obtain exact file size
	LDA #<KOALA_INFO_BUFFER
	STA ZP_IRQ_API_DATA_LO
	LDA #>KOALA_INFO_BUFFER
	STA ZP_IRQ_API_DATA_HI

	JSR PROT_DisableDisplay
	JSR PROT_GetInfoForFile
	BCC +                    ; If no error (Carry Clear), continue
	JMP ERRORREADING         ; If error (Carry Set), long jump
+	JSR PROT_EnableDisplay

	; Extract file size from FAT entry (bytes 28-31)
	LDA KOALA_INFO_BUFFER + 28
	STA ZP_LOADFILE_API_SIZE0
	LDA KOALA_INFO_BUFFER + 29
	STA ZP_LOADFILE_API_SIZE1
	LDA KOALA_INFO_BUFFER + 30
	STA ZP_LOADFILE_API_SIZE2
	LDA KOALA_INFO_BUFFER + 31
	STA ZP_LOADFILE_API_SIZE3

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
	JSR VIEWKOALA
	JMP INPUT_GET
ERRORCLOSING
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT ERRORCLOSINGFILE, 100		
	JMP EXITFAIL
INPUT_GET
	JSR SCNKEY		; Call kernal's key scan routine
 	JSR GETIN		; Get the pressed key by the kernal routine
  	BEQ INPUT_GET		; If zero then no key is pressed so repeat
	
EXITFAIL	
	JSR RESTORESTATE		; Restore VIC/$01 state for clean menu return
	JSR PROT_ExitToMenu
	JMP *
	
	
ERROR_BADSIZE
	JSR PROT_EnableDisplay
	PRINTSTATUSANDWAIT BADSIZE, 250
	JMP EXITFAIL

ERRORREADING	
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

PICTURE = $2000
 BITMAP = PICTURE
 VIDEO = PICTURE+$1f40
 COLOR = PICTURE+$2328
 BACKGROUND = PICTURE+$2710	
	
	
VIEWKOALA
	JSR FORCEIO			; Ensure I/O visible for VIC registers
	; Force VIC bank 0 ($0000-$3FFF) for bitmap $2000 + screen $0400
	LDA $DD00
	AND #$FC
	ORA #$03
	STA $DD00
 lda #$00
 sta $d020 ; Border Color
 lda BACKGROUND
 sta $d021 ; Screen Color

 ; Transfer Video and Color 
 ldx #$00
LOOPTRANSFER
 ; Transfers video data
 lda VIDEO,x
 sta $0400,x
 lda VIDEO+$100,x
 sta $0500,x
 lda VIDEO+$200,x
 sta $0600,x
 lda VIDEO+$2e8,x
 sta $06e8,x
 ; Transfers color data
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
 ;
 ; Bitmap Mode On
 ;
 lda #$3b
 sta $d011
 ;
 ; MultiColor On
 ;
 lda #$d8
 sta $d016
 ;
 ; When bitmap adress is $2000
 ; Screen at $0400 
 ; Value of $d018 is $18
 ;
 lda #$18
 sta $d018
 
	

	RTS



;------------------------------------------------------------
; Plugin local strings
;------------------------------------------------------------
BADSIZE
	.text "BAD KOALA SIZE",0

;------------------------------------------------------------
; State save/restore (so plugin returns cleanly to menu)
;------------------------------------------------------------
SAVED_01:       .byte 0
SAVED_DD00:     .byte 0
SAVED_D011:     .byte 0
SAVED_D016:     .byte 0
SAVED_D018:     .byte 0
SAVED_D020:     .byte 0
SAVED_D021:     .byte 0
SAVED_D022:     .byte 0
SAVED_D023:     .byte 0

FORCEIO
	LDA $01
	ORA #$04			; Ensure I/O visible ($D000-$DFFF)
	STA $01
	RTS

SAVESTATE
	LDA $01			; Processor port
	STA SAVED_01
	LDA $DD00
	STA SAVED_DD00
	LDA $D011
	STA SAVED_D011
	LDA $D016
	STA SAVED_D016
	LDA $D018
	STA SAVED_D018
	LDA $D020
	STA SAVED_D020
	LDA $D021
	STA SAVED_D021
	LDA $D022
	STA SAVED_D022
	LDA $D023
	STA SAVED_D023
	RTS

RESTORESTATE
	JSR FORCEIO
	LDA SAVED_01
	STA $01
	LDA SAVED_DD00
	STA $DD00
	LDA SAVED_D018
	STA $D018
	LDA SAVED_D016
	STA $D016
	LDA SAVED_D011
	STA $D011
	LDA SAVED_D020
	STA $D020
	LDA SAVED_D021
	STA $D021
	LDA SAVED_D022
	STA $D022
	LDA SAVED_D023
	STA $D023
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

READBUFFER