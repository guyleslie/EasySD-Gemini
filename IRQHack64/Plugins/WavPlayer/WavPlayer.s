; 4/8 bit Wav Player for IRQHack64V2
; 04/08/2018 - Istanbul
; I.R.on

.enc "screen"

STATUS		=$FE
CURSCROLL	=$A0
SCROLLCOS   =$A1
SCROLLCOLOR = $09

PLAYSTATE   = $A2
PLAYTYPE    = $A3
PLAYINDEX   = $A4

PLAYTYPE_ONLYSID = 0
PLAYTYPE_DIGIMAX = 1
PLAYTYPE_BOTH = 2



; DEBUG mode - defined from command line (-D DEBUG=1 or -D DEBUG=0)
; Load DEBUG macros BEFORE first use
.include "../../Loader/DebugMacros.s"

STREAMINGBUFFERHALF = 64

	*=$C000

	;*=$080E	
PETGLPLUGINREAD				;Remove when callback in the transfer code fixed.
	JMP MAIN
	
MAIN		
	JSR SAVESTATE		; Save VIC/$01 state for clean menu return
	JSR INIT		; Clears screen, disables interrupts.	
	JSR IRQ_StartTalking	; Initialize cartridge communication
	
ALTENTRY	
	CLD

;Lets try to open a file
	;PRINTSTATUSANDWAIT OPENINGFILE, 100
	DELAYFRAMES 5
	JSR IRQ_DisableDisplay		
	LDX #<CASSETTEBUFFER	
	LDY #>CASSETTEBUFFER
	LDA #31
	JSR IRQ_SetName
	LDX #01		; Flags=read
	JSR IRQ_OpenFile
	BCC OPENINGCONT
	JMP ERROR_OPENING_FILE
OPENINGCONT	
	JSR IRQ_EnableDisplay
	DELAYFRAMES 5
	;RINTSTATUSANDWAIT OPENINGSUCCESS, 200
	;JMP FILEREAD
	;RINTSTATUSANDWAIT STREAMINGFILE, 200

	; Use SafeStream wrapper with NORMAL profile
	; (Previously: direct IRQ_Stream call with hardcoded params)
	LDA #STREAM_NORMAL
	JSR SafeStream_Impl
	
	;JMP STREAMTEST2
	DELAYFRAMES 5
	LDA #PLAYTYPE_BOTH
	STA PLAYTYPE
	JMP STREAMFILE
	
ERROR_OPENING_FILE	
	JSR IRQ_EnableDisplay
	PRINTSTATUSANDWAIT OPENINGFILEFAILED, 200		
	JSR CleanReturnToMenu
	RTS

STREAMFILE
	LDA #0
	STA PLAYSTATE
	; PLAYINDEX is initialized inside SETUPMUSICTRANSFER
	JSR SETUPMUSICTRANSFER
	JSR IRQ_DisableDisplay
WAITAKEY
	JSR GETIN
	BEQ WAITAKEY
	JSR CleanReturnToMenu
	RTS
	;JSR minikey
  	;BEQ WAITAKEY	
	;SEI 
	;JSR $FDA3			; Init CIA
	;JSR $FD15			; Restore Vectors
	;DELAYFRAMES 10		; Wait for Cartridge to go back to command mode
	;JSR IRQ_CloseFile		; Close the file
	;JSR IRQ_DisableDisplay
	;JSR IRQ_ExitToMenu	


PlayRoutineSimple:
	PHA
	TXA
	PHA
	TYA
	PHA

	INC VIC_BORDER_COLOR			;is interrupt handler alive?
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT	
	LDA MODULATION_ADDRESS	
	NOP
	LDA CARTRIDGE_BANK_VALUE
	TAY
	LDA SHIFT4BIT, Y				; 4+	
	STA $D418

	LDA #PP_CONFIG_RAM_ON_ROM
	STA PROCESSOR_PORT		
	LDA CIA_1_BASE + CIA_INT_MASK	; Acknowledge interrupt

	PLA
	TAY
	PLA
	TAX
	PLA
	RTI	
	
PlayRoutineBoth:
	PHA
	TXA
	PHA
	TYA
	PHA

	INC VIC_BORDER_COLOR			;is interrupt handler alive?
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT	
	LDA MODULATION_ADDRESS	
	NOP
	LDA CARTRIDGE_BANK_VALUE
	TAY
	LDA SHIFT4BIT, Y				; 4+	
	STA $D418
	STY CIA_2_BASE + DATA_B			; 8-bit Digimax
	
	LDA #PP_CONFIG_RAM_ON_ROM
	STA PROCESSOR_PORT		
	LDA CIA_1_BASE + CIA_INT_MASK	; Acknowledge interrupt

	PLA
	TAY
	PLA
	TAX
	PLA
	RTI	
	
.align $100	

PlayRoutine							; 7
	PHA
	TXA
	PHA
	TYA
	PHA

	INC VIC_BORDER_COLOR			; 6
	LDA PLAYSTATE					; 3
	BNE PlayFromBuffer				; 2 - 3

	LDA #PP_CONFIG_DEFAULT			; 2
	STA PROCESSOR_PORT	 			; 3

	LDA MODULATION_ADDRESS			; 4
	NOP								; 2
	LDA CARTRIDGE_BANK_VALUE		; 4
	LDX PLAYINDEX
	STA READBUFFER, X				; 5
	TAY								; 2
	LDA SHIFT4BIT, Y				; 4+
	STA $D418						; 4
	
	DEX								; 2
	BNE +							; 2-3
	INC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	LDA #PP_CONFIG_RAM_ON_ROM		; 2
	STA PROCESSOR_PORT				; 4
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt		
	
	PLA
	TAY
	PLA
	TAX
	PLA
	RTI
		
PlayFromBuffer	
	LDX PLAYINDEX
	LDA READBUFFER, X				; 4+ (if page crossed)
	TAY								; 2
	LDA SHIFT4BIT, Y				; 4+
	STA $D418						; 4
	DEX								; 2
	BNE +							; 2 - 3
	DEC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	LDA #PP_CONFIG_RAM_ON_ROM		; 2
	STA PROCESSOR_PORT				; 4
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt	

	PLA
	TAY
	PLA
	TAX
	PLA
	RTI								; 6
		
.align $100	

PlayDigimax							; 7
	PHA
	TXA
	PHA
	TYA
	PHA

	INC VIC_BORDER_COLOR			; 6
	LDA PLAYSTATE					; 3
	BNE PlayFromBufferDigimax		; 2 - 3

	LDA #PP_CONFIG_DEFAULT			; 2
	STA PROCESSOR_PORT	 			; 3

	LDA MODULATION_ADDRESS			; 4
	NOP								; 2
	LDA CARTRIDGE_BANK_VALUE		; 4
	LDX PLAYINDEX
	STA READBUFFER, X				; 5
	STA CIA_2_BASE + DATA_B			; 4
	
	DEX								; 2
	BNE +							; 2-3
	INC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	LDA #PP_CONFIG_RAM_ON_ROM		; 2
	STA PROCESSOR_PORT				; 4
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt		

	PLA
	TAY
	PLA
	TAX
	PLA
	RTI
		
PlayFromBufferDigimax
	LDX PLAYINDEX
	LDA READBUFFER, X				; 4+ (if page crossed)
	STA CIA_2_BASE + DATA_B			; 4
	DEX								; 2
	BNE +							; 2 - 3
	DEC PLAYSTATE					; 5
	LDX #STREAMINGBUFFERHALF		; 2
+	
	STX PLAYINDEX
	LDA #PP_CONFIG_RAM_ON_ROM		; 2
	STA PROCESSOR_PORT				; 4
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt	

	PLA
	TAY
	PLA
	TAX
	PLA
	RTI				
	
	
PlayDigimaxSimple					; 7
	
	
	PHA
	
	
	TXA
	
	
	PHA
	
	
	TYA
	
	
	PHA
	
	

	
	
	INC VIC_BORDER_COLOR			; 6
	
	
	LDA #PP_CONFIG_DEFAULT			; 2
	
	
	STA PROCESSOR_PORT	 		; 3
	
	

	
	
	LDA MODULATION_ADDRESS			; 4
	
	
	NOP						; 2
	
	
	NOP
	
	
	NOP
	
	
	LDA CARTRIDGE_BANK_VALUE		; 4
	
	
	STA CIA_2_BASE + DATA_B			; 4
	
	
	LDA #PP_CONFIG_RAM_ON_ROM		; 2
	
	
	STA PROCESSOR_PORT			; 4
	
	
	LDA CIA_1_BASE + CIA_INT_MASK	; 4 - Acknowledge interrupt		
	
	

	
	
	PLA
	
	
	TAY
	
	
	PLA
	
	
	TAX
	
	
	PLA
	
	
	RTI
	
	

	
	
PlayBothBuffered:
	
	
	PHA
	
	
	TXA
	
	
	PHA
	
	
	TYA
	
	
	PHA
	
	

	
	
	INC VIC_BORDER_COLOR
	
	
	LDA PLAYSTATE
	
	
	BNE +
	
	

	
	
	LDA #PP_CONFIG_DEFAULT
	
	
	STA PROCESSOR_PORT
	
	
	LDA MODULATION_ADDRESS
	
	
	NOP
	
	
	LDA CARTRIDGE_BANK_VALUE
	
	
	LDX PLAYINDEX
	
	
	STA READBUFFER, X
	
	
	TAY
	
	
	LDA SHIFT4BIT, Y
	
	
	STA $D418
	
	
	STY CIA_2_BASE + DATA_B
	
	
	
	
	
	DEX
	
	
	BNE _not_zero
	
	
	INC PLAYSTATE
	
	
	LDX #STREAMINGBUFFERHALF
	
	
_not_zero
	
	
	STX PLAYINDEX	
	
	JMP PlayBothBuffered_Exit
	
	

	
	
+	; Play from buffer
	
	
	LDX PLAYINDEX
	
	
	LDA READBUFFER, X
	
	
	TAY
	
	
	LDA SHIFT4BIT, Y
	
	
	STA $D418
	
	
	STY CIA_2_BASE + DATA_B
	
	
	
	
	
DEX
	
	
	BNE +
	
	
	DEC PLAYSTATE
	
	
	LDX #STREAMINGBUFFERHALF
	
	
+
	
	
	STX PLAYINDEX
	
	

	
	
PlayBothBuffered_Exit:
	
	
	LDA #PP_CONFIG_RAM_ON_ROM
	
	
	STA PROCESSOR_PORT
	
	
	LDA CIA_1_BASE + CIA_INT_MASK
	
	
	PLA
	
	
	TAY
	
	
	PLA
	
	
	TAX
	
	
	PLA
	
	
	RTI
	
	

	
	
SETUPMUSICTRANSFER	
	
	
	JSR IRQ_DisableDisplay
	
	
	SEI
	
	
	LDA #PP_CONFIG_RAM_ON_ROM		
	
	
	STA PROCESSOR_PORT	
	
	
	
	
	
	LDA #STREAMINGBUFFERHALF
	
	
	STA PLAYINDEX
	
	

	
	
	LDA PLAYTYPE
	
	
	CMP #PLAYTYPE_ONLYSID			
	
	
	BEQ SetupSidOnly
	
	
	CMP #PLAYTYPE_DIGIMAX
	
	
	BEQ SetupDigimax
	
	
	CMP #PLAYTYPE_BOTH
	
	
	BEQ SetupBoth					; TODO : Handle
	
	
	
	
	

	
	
SetupBoth:
	
	
	JSR DIGI_Init
	
	
	JSR NMIDIGI_InitNew	
	
	
	LDA #<PlayBothBuffered
	
	
	STA ROM_IRQ_HANDLER
	
	
	LDA #>PlayBothBuffered
	
	
	STA ROM_IRQ_HANDLER+1
	
	

	
	
	LDA #$00
	
	
	BEQ SetupInterrupt			;Fake unconditional
	
	
	
	
	
		
	
	
SetupSidOnly:
	
	
	JSR DIGI_Init
	
	
	LDA #<PlayRoutine
	
	
	STA ROM_IRQ_HANDLER
	
	
	LDA #>PlayRoutine
	
	
	STA ROM_IRQ_HANDLER+1
	
	

	
	
	LDA #$00
	
	
	BEQ SetupInterrupt			;Fake unconditional
	
	
SetupDigimax:	
	
	
	JSR NMIDIGI_InitNew
	
	

	
	
	LDA #<PlayDigimax
	
	
	STA ROM_IRQ_HANDLER
	
	
	LDA #>PlayDigimax
	
	
	STA ROM_IRQ_HANDLER+1
	
	

	
	
	LDA #$00	
	
	
	
	
	
SetupInterrupt:
	LDA #$00
	STA CIA_1_BASE + TIMER_A_HI

	LDA #89							;985000/11000 = 89
	STA CIA_1_BASE + TIMER_A_LO

	LDA #$81						; Enable Timer A interrupts	
	STA CIA_1_BASE + CIA_INT_MASK
	
	LDX #(CRA_FORCE_LOAD + CRA_START)		;Continous
	STX CIA_1_BASE + CIA_TIMER_A_CTRL			
		
	LDA #02				
   	STA BORDER
	LDA CIA_1_BASE + CIA_INT_MASK
	CLI	
	
	RTS
	
NMIDIGI_InitNew:

	LDA CIA_2_BASE + DDR_A
	ORA #$0C
	STA CIA_2_BASE + DDR_A			;Set PA2/PA3 as output		
	
	LDA CIA_2_BASE + DATA_A
	ORA #$08						;PA3 = 1, PA2 = 0 (Select first dac output)
	STA CIA_2_BASE + DATA_A
	
	LDA #$FF
	STA CIA_2_BASE + DDR_B			;Set PB0..PB7 as output
	
	RTS
	
DIGI_Init:
	LDA #$FF
	STA $D406
	STA $D406+7
	STA $D406+14
	LDA #$49
	STA $D404
	STA $D404+7
	STA $D404+14

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
	JSR PREPARESHIFTBIT
		
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
	
PREPARESHIFTBIT
	LDX #0
-	
	TXA
	LSR
	LSR
	LSR
	LSR
	STA SHIFT4BIT, X
	INX
	BNE -
	RTS


	
	
STREAMTEST1
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT	

WAIT1
	JSR minikey
  	BEQ WAIT1
	
	JSR IRQ_DisableDisplay

	LDA MODULATION_ADDRESS
	NOP
	LDA CARTRIDGE_BANK_VALUE
	STA $FB
	JSR DisplayReceived1	
	DELAYFRAMES 25

	JSR IRQ_EnableDisplay
	JMP WAIT1
	
	
STREAMTEST2
	LDA #PP_CONFIG_DEFAULT
	STA PROCESSOR_PORT	

WAIT2
	JSR minikey
  	BEQ WAIT2
	
	JSR IRQ_DisableDisplay

	LDA MODULATION_ADDRESS
	NOP
	LDA CARTRIDGE_BANK_VALUE
	TAX
	LDA CARTRIDGE_BANK_VALUE
	TAY
	JSR DisplayReceived2	
	DELAYFRAMES 50

	JSR IRQ_EnableDisplay
	JMP WAIT2
	
	
	
; X have first byte, 	Y have second byte
DisplayReceived1
	JSR GetHigh
	STA $0400
	
	LDA $FB
	JSR GetLow
	STA $0401
	
	LDX $FB
	LDA SHIFT4BIT, X
	TAX
	LDA  HEXTOSCREEN, X	
	
	STA $0405
		
	RTS
	
; X have first byte, 	Y have second byte
DisplayReceived2
	STX $FB
	STY $FC

	LDA $FB
	JSR GetHigh
	STA $0400
	
	LDA $FB
	JSR GetLow
	STA $0401
	
	LDA $FC
	JSR GetHigh
	STA $0403
	
	LDA $FC
	JSR GetLow
	STA $0404
	
	LDX $FB
	LDA SHIFT4BIT, X
	TAX
	LDA  HEXTOSCREEN, X	
	STA $0408
	
	LDY $FC
	LDA SHIFT4BIT, X
	TAX
	LDA  HEXTOSCREEN, X		
	STA $040B
	
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
	
.align $100	
SHIFT4BIT
	.FILL 256

READBUFFER
	.FILL 128
		
HEXTOSCREEN
	.BYTE 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 1, 2, 3, 4, 5, 6
INITTEXT
	.TEXT "IRQHACK64V2 WAV TEST"
	.BYTE 0	
	
SENDSTARTTALKING
	.TEXT "SENDING START TALKING COMMAND"
	.BYTE 0		

STARTEDTALKING
	.TEXT "STARTED TALKING"
	.BYTE 0		

OPENINGFILE
	.TEXT "OPENING WAV FILE"
	.BYTE 0		

OPENINGFILEFAILED
	.TEXT "OPENING WAV FILE FAILED"
	.BYTE 0	

OPENINGSUCCESS
	.TEXT "FILE OPEN SUCCEEDED"
	.BYTE 0		
	
STREAMINGFILE
	.TEXT "STREAMING FILE"
	.BYTE 0		


READINGFAILED	
	.TEXT "READING FAILED"
	.BYTE 0		
CLOSINGFILE	
	.TEXT "CLOSING FILE"
	.BYTE 0	
	
FILECLOSED
	.TEXT "FILE CLOSING SUCCEEDED"
	.BYTE 0
	
	
ERRORCLOSINGFILE
	.TEXT "CLOSING FAILED"
	.BYTE 0	

DEMOFILE
	.TEXT "test.wav"
	.BYTE 0
DEMOFILEEND


;------------------------------------------------------------
; Clean return to menu (stop CIA IRQs, close file, restore VIC/$01)
;------------------------------------------------------------
CleanReturnToMenu
	SEI
	LDA #$7F
	STA $DC0D			; Disable all CIA1 interrupts
	LDA $DC0D			; Ack pending
	LDA #$00
	STA $D01A			; Disable VIC raster IRQs
	CLI

	JSR IRQ_CloseFile		; Safe even if already closed
	JSR IRQ_EndTalking		; End cartridge communication
	JSR RESTORESTATE		; Restore VIC/$01 state
	JSR IRQ_DisableDisplay
	JSR IRQ_ExitToMenu
	RTS

;------------------------------------------------------------
; Clean return helpers (shared pattern with Koala/Petscii/MUS)
;------------------------------------------------------------
FORCEIO
	LDA $01
	ORA #$04			; Ensure I/O visible ($D000-$DFFF)
	STA $01
	RTS

SAVESTATE
	LDA $01
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

SAVED_01:	.byte 0
SAVED_DD00:	.byte 0
SAVED_D011:	.byte 0
SAVED_D016:	.byte 0
SAVED_D018:	.byte 0
SAVED_D020:	.byte 0
SAVED_D021:	.byte 0
SAVED_D022:	.byte 0
SAVED_D023:	.byte 0

.include "../../Loader/CartLibStream.s"
.include "../../Loader/SafeStreamImpl.s"