; PRG plugin for IRQHack64V2
; Aim : Replace standard kernal functions so that basic tools using standard kernal can work with IRQHack64V2
; 26/08/2018 - Istanbul
; I.R.on


.enc "screen"

; --- PrgPlugin Constants ---
FAT_FILE_LENGTH_INDEX = 28
LOAD_START_LO         = $AE
LOAD_START_HI         = $AF

; DEBUG mode - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Load DEBUG macros BEFORE first use
.include "../../Loader/DebugMacros.s"


EQ16	.macro
	LDA #<\1
	CMP #<\2 
	BNE +
	LDA #>(\1 + 1)
	CMP #>(\2 + 1)
+
	.endm
	
INC16	.macro
	INC \1
	BNE +
	INC \1 + 1
+	
	.endm
	
ADD16	.macro
	CLC 
	LDA \1
	ADC \2
	STA \3
	LDA \1 + 1
	ADC \2 + 1
	STA \3 + 1
	.endm
	
	
	*=$C000
	JMP MAIN
	
	*=$C700
MAIN	
	JSR INIT		;Clears screen, disables interrupts.	

;Lets try to open a file
	PRINTSTATUSANDWAIT OPENINGFILE, 100
	JSR IRQ_DisableDisplay
	; CRITICAL: Start protocol session - MUST call IRQ_EndTalking on ALL exit paths
	JSR IRQ_StartTalking
	LDX #<FILE_PATH_BUF
	LDY #>FILE_PATH_BUF
	LDA #31
	JSR IRQ_SetName
	LDX #01		; Flags=read
	JSR IRQ_OpenFile
	BCC OPENINGCONT
	JMP MAIN_ERROR_EXIT
OPENINGCONT	
	JSR IRQ_EnableDisplay

	PRINTSTATUSANDWAIT OPENINGSUCCESS, 200

	LDA #<GENERALBUFFER
	STA ZP_IRQ_API_DATA_LO
	LDA #>GENERALBUFFER
	STA ZP_IRQ_API_DATA_HI
	
	JSR IRQ_DisableDisplay
	
	LDY #$00
	JSR IRQ_GetInfoForFile
	JSR ERROR_GATE

	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX
	STA FILELENGTH
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX + 1
	STA FILELENGTH + 1
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX + 2
	STA FILELENGTH + 2
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX + 3
	STA FILELENGTH + 3
		
	DELAYFRAMES 2		

	; === Refactored PRG Loading Logic (using LoadFileBySize) ===
	; Step 1: Read first page to get PRG load address
	LDA #<GENERALBUFFER
	STA ZP_IRQ_API_DATA_LO
	LDA #>GENERALBUFFER
	STA ZP_IRQ_API_DATA_HI
	LDA #1
	STA ZP_IRQ_API_DATA_LENGTH
	JSR IRQ_ReadFileNoCallback
	JSR ERROR_GATE
	DELAYFRAMES 2

	; Step 2: Parse load address from header
	LDA GENERALBUFFER
	STA STARTADDRESSLO
	STA ZP_IRQ_API_DATA_LO
	LDA GENERALBUFFER + 1
	STA STARTADDRESSHI
	STA ZP_IRQ_API_DATA_HI

	; Step 3: Setup parameters for LoadFileBySize
	; Copy 32-bit file size from local FILELENGTH to ZP locations
	LDA FILELENGTH
	STA ZP_LOADFILE_API_SIZE0
	LDA FILELENGTH + 1
	STA ZP_LOADFILE_API_SIZE1
	LDA FILELENGTH + 2
	STA ZP_LOADFILE_API_SIZE2
	LDA FILELENGTH + 3
	STA ZP_LOADFILE_API_SIZE3

	; Set skip bytes for PRG header
	LDA #2
	STA ZP_LOADFILE_API_SKIP_LO
	LDA #0
	STA ZP_LOADFILE_API_SKIP_HI

	; Step 4: Call the centralized loader
	JSR LoadFileBySize
	JSR ERROR_GATE

	; Recalculate ENDADDRESS for the LAUNCH logic
	ADD16 STARTADDRESS, FILELENGTH16BIT, ENDADDRESS
	
RESUMEFULLLOAD
	DELAYFRAMES  2
	JSR IRQ_CloseFile
	JSR ERROR_GATE

	JSR IRQ_EndTalking
	JSR ERROR_GATE

	; Now we need to change the kernal vectors and launch the program.
	; GET BACK HERE - GET BACK HERE - GET BACK HERE 
	
	STX $D016					; Turn on VIC for PAL / NTSC check
	JSR $FDA3					; IOINIT - Init CIA chips
	;JSR $FD50					; RANTAM - Clear/test system RAM
	;JSR ALTRANTAM				; Metallic's fast alternative to RANTAM
	JSR $FD15					; RESTOR - Init KERNAL RAM vectors
	JSR $FF5B					; CINT   - Init VIC and screen editor
	JSR SETVECTORS	
	CLI							; Re-enable IRQ interrupts	

;	BASIC RESET  Routine

	JSR $E453					; Init BASIC RAM vectors
	JSR $E3BF					; Main BASIC RAM Init routine
	JSR $E422					; Power-up message / NEW command
	LDX #$FB
	TXS		
	
	
	LDY ENDADDRESSLO
	STY $2D
	STY $2F
	STY LOAD_START_LO
	LDA ENDADDRESSHI
	STA $2E
	STA $30
	STA LOAD_START_HI
	
	JSR CLEANUP
		
	LDA #$37					;Restore default memory layout
	STA $01	
	
	JSR IRQ_EnableDisplay
	
	LDA #$08					;Initialize current device number as 8
	STA $BA
	
	LDA #$81					;%10000001 ; Enable CIA interrupts
	STA $DC0D	
		
	JMP $0840
		
LAUNCH	
	LDA #$08					
	CMP STARTADDRESSHI
	BNE MACHINELANG				
	LDA STARTADDRESSLO
	CMP #$01
	BNE MACHINELANG
		
	JSR $A659 ;"CLR" 	
	JMP $A7AE ;"RUN" 
 	
MACHINELANG 
	LDA STARTADDRESSLO
	STA $FB
	LDA STARTADDRESSHI
	STA $FC
	JMP ($00FB)				; Leave control to loaded stuff 	
			
	
	
; --------------------------------------------------
; Error Gate: Carry set -> fatal error
; Centralized error handling - prevents branch distance issues
; --------------------------------------------------
ERROR_GATE
	BCC +
	JMP EXITFAIL
+
	RTS


INPUT_GET
	JSR SCNKEY		; Call kernal's key scan routine
 	JSR GETIN		; Get the pressed key by the kernal routine
  	BEQ INPUT_GET		; If zero then no key is pressed so repeat

; --------------------------------------------------
; MAIN_ERROR_EXIT: Cleanup handler for MAIN section errors
; Ensures IRQ_EndTalking is called before error exit
; --------------------------------------------------
MAIN_ERROR_EXIT
	JSR IRQ_EndTalking	; CRITICAL: Cleanup protocol session
	; Fall through to EXITFAIL

EXITFAIL
.if DEBUG = 1
	LDA #$02
	STA DEBUG_ERROR_CODE		; Store error code for debugging
.endif
	LDA #$02
	STA BORDER
	JSR IRQ_EnableDisplay

	JMP INPUT_GET
	
	
CLEANUP
	; Restore nmi vector
	LDA #<DEFAULT_NMI_HANDLER
	STA NMI_LO
	LDA #>DEFAULT_NMI_HANDLER
	STA NMI_HI	

	RTS
	
SETVECTORS
	LDA #<NEW_CHRIN
	STA V_CHRIN
	LDA #>NEW_CHRIN
	STA V_CHRIN	+ 1
	
	LDA #<NEW_OPEN
	STA V_OPEN 
	LDA #>NEW_OPEN
	STA V_OPEN 	+ 1
	
	LDA #<NEW_CLOSE
	STA V_CLOSE  
	LDA #>NEW_CLOSE
	STA V_CLOSE + 1	

	LDA #<NEW_CHKIN
	STA V_CHKIN  
	LDA #>NEW_CHKIN
	STA V_CHKIN + 1	

	LDA #<NEW_CLRCHN
	STA V_CLRCHN  
	LDA #>NEW_CLRCHN
	STA V_CLRCHN + 1	
	RTS
	
	
INIT		; Input : None, Changed : A
	CLD
	LDA #$93
	JSR CHROUT
;	LDA #$00 
;	STA $D020
;	LDA #$0B
;	STA $D021
		
	JSR DISABLEINTERRUPTS		
	JSR KILLCIA
		
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


TALK_STATUS
	.BYTE $00
TALK_DIRECTION
	.BYTE $00
TALK_FILE
	.BYTE $00	
HAS_OPENED_FILE
	.BYTE $00


NEW_OPEN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ + 
	JMP K_OPEN
+
	JSR IRQ_DisableDisplay
	JSR IRQ_StartTalking
	DELAYFRAMES 2
	; Load filename pointer from KERNAL zero page ($BB/$BC)
	; CRITICAL: Use zero page CONTENT, not ADDRESS
	LDX KERNAL_FILENAME_LOW
	LDY KERNAL_FILENAME_HIGH
	LDA KERNAL_FILENAME_LENGTH
	JSR IRQ_SetName
	LDX #01		; Flags=read
	JSR IRQ_OpenFile
	BCC OPEN_SUCCESS
	; CRITICAL: Cleanup protocol session on error
	JSR IRQ_EndTalking
	LDA #128
	SEC
	JMP NEW_OPEN_FINISH
OPEN_SUCCESS
	DELAYFRAMES 2
	LDA #<GENERALBUFFER
	STA ZP_IRQ_API_DATA_LO
	LDA #>GENERALBUFFER
	STA ZP_IRQ_API_DATA_HI
	LDY #$00
	JSR IRQ_GetInfoForFile
	
	BCC +
	; CRITICAL: Cleanup protocol session on error
	JSR IRQ_EndTalking
	LDA #128
	SEC
	JMP NEW_OPEN_FINISH
+
	DELAYFRAMES 2
	JSR IRQ_EndTalking

	
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX
	STA OPENEDFILELENGTH
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX + 1
	STA OPENEDFILELENGTH + 1
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX + 2
	STA OPENEDFILELENGTH + 2
	LDA GENERALBUFFER + FAT_FILE_LENGTH_INDEX + 3
	STA OPENEDFILELENGTH + 3
		
	
	LDA #0
	STA FILEINDEX
	STA FILEINDEX+1
	LDA #1		
	STA HAS_OPENED_FILE	
	EQ16 OPENEDFILELENGTH16BIT, 0
	BNE +
	LDA #64
	SEC
	JMP NEW_OPEN_FINISH
+	
	CLC
	LDA #0
NEW_OPEN_FINISH
	STA KERNAL_STATUS
	JSR IRQ_EnableDisplay	
	
	RTS
	
NEW_CHKIN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ +
	JMP K_CHKIN
+
	STX TALK_FILE
	LDA #$00
	STA TALK_DIRECTION		; Program wants to read
	STA KERNAL_STATUS		; Clear status (success)
	CLC						; Clear carry (no error)
	RTS
	
NEW_CLOSE
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ + 
	JMP K_CLOSE
+
	JSR IRQ_DisableDisplay
	
	JSR IRQ_StartTalking

	DELAYFRAMES 2
	JSR IRQ_CloseFile
	BCC +
	; CRITICAL: Cleanup protocol session on error
	JSR IRQ_EndTalking
	LDA #128
	STA KERNAL_STATUS
	SEC
	RTS
+
	DELAYFRAMES 2
	JSR IRQ_EndTalking
	RTS

NEW_CLRCHN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ + 
	JMP K_CLRCHN
+
	RTS
	
	;First chrin will be pulling 256 bytes from the micro
	;then it will serve the calling program from this buffer.
	;for the next 256 bytes it will call the micro again.
	;so this way calling program will be able to invoke other api functions like close and such.
NEW_CHRIN
	INC $D020
	LDA KERNAL_DEVICE_NUMBER
	CMP #08
	BEQ + 
	JMP K_CHRIN
+
	; Check EOF: FILEINDEX == OPENEDFILELENGTH16BIT?
	; CRITICAL: Compare CONTENT, not ADDRESSES!
	LDA FILEINDEXLOW
	CMP OPENEDFILELENGTH
	BNE +						; Low bytes different, not EOF
	LDA FILEINDEXHIGH
	CMP OPENEDFILELENGTH+1
	BNE +						; High bytes different, not EOF
	; EOF reached - KERNAL convention
	LDA #$40					; EOF bit (bit 6 of STATUS)
	STA KERNAL_STATUS
	LDA #$00					; Return null byte (KERNAL EOF convention)
	CLC							; No error
	RTS
+	
	LDA FILEINDEXLOW
	BNE +			;Read from already filled buffer

	JSR IRQ_StartTalking
	DELAYFRAMES 2
	
	LDY #$00
	LDA #<GENERALBUFFER
	STA ZP_IRQ_API_DATA_LO
	LDA #>GENERALBUFFER
	STA ZP_IRQ_API_DATA_HI
	LDA #1

	STA ZP_IRQ_API_DATA_LENGTH
	JSR IRQ_ReadFileNoCallback
	BCC +						; If carry clear, success
	; Read error handling
	; CRITICAL: Cleanup protocol session on error
	JSR IRQ_EndTalking
	LDA #128					; Read error flag
	STA KERNAL_STATUS
	SEC							; Set carry (error)
	RTS
+
	DELAYFRAMES 2
	JSR IRQ_EndTalking
	BCC +						; Check EndTalking success
	; EndTalking error handling
	LDA #128					; Communication error flag
	STA KERNAL_STATUS
	SEC							; Set carry (error)
	RTS
+
	LDA #$00
	STA KERNAL_STATUS
	
	LDX FILEINDEXLOW
	LDA GENERALBUFFER, X	
	TAY
	INC16 FILEINDEX
	TYA	
	RTS
	
	


.include "../../Loader/CartLibStream.s"
.include "../../Loader/DebugStrings.s"

DUMPHEX	.macro
	; \1 -> source addresses
	; \2 -> dump destination
	; \3 -> length
	
	; Init self modified addresses	
	LDA #<\1
	STA DATASOURCE+1
	
	LDA #<\2
	STA HNIBBLESTORE+1
	
	LDA #<\2 + 1
	STA LNIBBLESTORE+1	

	LDA #>\1
	STA DATASOURCE+2
	LDA #>\2
	STA HNIBBLESTORE+2
	LDA #>\2
	STA LNIBBLESTORE+2
	
	LDY #0
-	
DATASOURCE	
	LDA \1,Y
	JSR GetHigh
HNIBBLESTORE	
	STA \2
	
	LDA \1,Y
	JSR GetLow
LNIBBLESTORE
	STA \2 + 1

	INC16 HNIBBLESTORE+1
	INC16 HNIBBLESTORE+1
	INC16 LNIBBLESTORE+1
	INC16 LNIBBLESTORE+1
	INY
	CPY #\3
	BNE - 
	.endm	
	
	; X have first byte, 	Y have second byte
DisplayReceived	
	DUMPHEX GENERALBUFFER, $0400, $00	
	DUMPHEX GENERALBUFFER+256, $0700, $10		
	
	RTS
	

GetHigh
	LSR
	LSR
	LSR
	LSR
	TAX
	LDA  HEXTOSCREEN, X
	RTS

GetLow
	AND #$0F
	TAX
	LDA  HEXTOSCREEN, X
	RTS
	
minikey:
	lda #$0
	sta $dc03	; port b ddr (input)
	lda #$ff
	sta $dc02	; port a ddr (output)
			
	lda #$00
	sta $dc00	; port a
	lda $dc01       ; port b
	cmp #$ff
	beq nokey
	; got column
	tay
			
	lda #$7f
	sta nokey2+1
	ldx #8
nokey2:
	lda #0
	sta $dc00	; port a
	
	sec
	ror nokey2+1
	dex
	bmi nokey
			
	lda $dc01       ; port b
	cmp #$ff
	beq nokey2
			
	; got row in X
	txa
	ora columntab,y
	sec
	rts
			
nokey:
	clc
	rts

columntab:
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $70
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $60
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $50
.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,$FF, $FF, $FF, $FF,$FF, $FF, $FF, $40,$FF, $FF, $FF, $FF, $FF, $FF, $FF, $30,$FF, $FF, $FF, $20,$FF, $10, $00, $FF

HEXTOSCREEN
	.BYTE 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6

GENERALBUFFER
	.FILL 256

; Attributes of launched initial program file	
FILELENGTH16BIT	; F9 36
FILELENGTH
	.FILL 4

STARTADDRESS	; 01 08
STARTADDRESSLO
	.BYTE 0	
STARTADDRESSHI
	.BYTE 0
	
ENDADDRESS		; FA 3E
ENDADDRESSLO
	.BYTE 0	
ENDADDRESSHI
	.BYTE 0	


; Attributes of opened files	
OPENEDFILELENGTH16BIT	; FA 3E
OPENEDFILELENGTH
	.FILL 4

FILEINDEX		; FF FF ; We are supporting only files with 16 bit size at the moment
FILEINDEXLOW
	.FILL 1
FILEINDEXHIGH
	.FILL 1

;-----------------------------------------------
; DEBUG Status Strings moved to DebugStrings.s
; (Common file shared across plugins)
;-----------------------------------------------


