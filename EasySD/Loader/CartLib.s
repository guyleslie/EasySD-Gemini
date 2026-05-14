;----------------------------------------------------------------------------------------------------------
; Low level interface to the IRQHack64 cartridge.
;----------------------------------------------------------------------------------------------------------
; Routines that are exposed are as below.
; PROT_StartTalking
; PROT_EndTalking
; PROT_Send
; PROT_SendFragment
; PROT_ReceiveFragment
;
; Code is relocatable and fits into the datasette buffer. 
; Refer to the CartLibHi for more higher level api for interfacing to the cartridge.
;----------------------------------------------------------------------------------------------------------

.include "CartLibCommon.s"
.include "SystemMacros.s"

;----------- Utility routines ----------------------

;MODULATION_ADDRESS	= $DF00

;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
PROT_DisableVICInterrupts
	ASL VIC_INT_ACK
	LDA #$00
	STA VIC_INT_CONTROL	
	RTS

;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
PROT_DisableCIAInterrupts
	LDA #$7f    					; $7f = %01111111 
    STA CIA_1_BASE + CIA_INT_MASK	; Turn off CIA 1 interrupts 
    STA CIA_2_BASE + CIA_INT_MASK	; Turn off CIA 2 interrupts 	
    LDA CIA_1_BASE + CIA_INT_MASK	; cancel all CIA-IRQs in queue/unprocessed 
    LDA CIA_2_BASE + CIA_INT_MASK	; cancel all CIA-IRQs in queue/unprocessed 
	RTS
	
;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
PROT_DisableInterrupts
	JSR PROT_DisableVICInterrupts
	JSR PROT_DisableCIAInterrupts
	RTS


	
	

	
NMITAB	
	.BYTE <CARTRIDGENMIHANDLERX1, <CARTRIDGENMIHANDLERX4,<CARTRIDGENMIHANDLERX8


;----------- API routines ----------------------
	
; Sends a special set of bytes to wake the cartridge to listen for actual
; commands. With the esp8266 version sending is accomplished using two ports so
; IRQs are not used.
;-----------------------------------------
;Registers In : None
;Registers Used : A
;-----------------------------------------
PROT_StartTalking
	SEI
	JSR PROT_DisableInterrupts
		
	LDA #$64;#73							; I	
	JSR PROT_Send
	LDA #$46;#82							; R	
	JSR PROT_Send
	LDA #$17;#81							; Q	
	JSR PROT_Send
		
	RTS

;-----------------------------------------
;Registers In : None
;Registers Used : A
;-----------------------------------------
PROT_EndTalking
	LDA #30							;End Talking command
	JSR PROT_Send
	SEI
	JSR PROT_DisableCIAInterrupts
		
	#SETBANK PP_CONFIG_DEFAULT
	CLI
	RTS
	

	
;-----------------------------------------
;Registers In : A (Byte to send)
;Registers Used : X
;-----------------------------------------
PROT_SendBit
	JSR WasteTooMuchTime
	LSR
	BCC +
	LDX #12						; ONE: long pulse (~24µs)
	BNE _continue					; Fake unconditional jump, to make code relocatable.
+
	LDX #6						; ZERO: short pulse (~12µs)
_continue
	
	LDY MODULATION_ADDRESS						; Cause interrupt on Attiny85
	JSR WasteCertainTime		
	LDY MODULATION_ADDRESS

		

	RTS
	

WasteCertainTime
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

WasteTooMuchTime
	LDX #1						; Inter-bit gap counter (was #15 in ATtiny85 era)
OUTERWASTE	
	LDY #$FF
-	
	DEY
	NOP
	BNE -
	DEX
	BNE OUTERWASTE
	RTS
	


;----------- API routines ----------------------
	


; We will send 
; long interval Kernal Accesses for transmitting 1
; short interval Kernal Accesses for transmitting 0
; The idea here is : Receiver will measure the signal on /OE line. 
; It will measure how long the signal is kept high between two low states. (L/H/L) __|''|__
; If its in the range say N-Epsilon, N+Epsilon than c64 is transmitting a ZERO
; If its in the range say N*2-Epsilon, N*2+Epsilon than c64 is transmitting a ONE
;-----------------------------------------
; Registers In : A (Byte to send)
; Registers Used : X
;-----------------------------------------
PROT_Send
	STA ZP_IRQ_TMP_SCRATCH
	TXA
	PHA
	TYA
	PHA
	LDA ZP_IRQ_TMP_SCRATCH
	
	JSR PROT_SendBit
	JSR PROT_SendBit
	JSR PROT_SendBit
	JSR PROT_SendBit	
	JSR PROT_SendBit
	JSR PROT_SendBit
	JSR PROT_SendBit
	JSR PROT_SendBit
	
	PLA
	TAY
	PLA
	TAX
	
	RTS
	
	


; Use to send buffered 32 bytes to the micro. (For ex. writing to a file)
;-----------------------------------------
; Setup : 
; ZP_IRQ_API_DATA_LO = $69
; ZP_IRQ_API_DATA_HI = $6A
;-----------------------------------------
; Registers in : None
; Registers used : A, X, Y
;-----------------------------------------
PROT_SendFragment
	LDY #$00
-	
	LDA (ZP_IRQ_API_DATA_LO), Y
	JSR PROT_Send
	INY				; Advance to next byte (was missing — infinite-loop bug)
	CPY #$20			; Done when 32 bytes sent
	BNE -
	RTS


; Reads/Receives content from currently opened file. Caller supplies the target address
; where the data will be transferred. Caller supplies return address at
; ZP_IRQ_API_CALLBACK_LO / ZP_IRQ_API_CALLBACK_HI and this routine resumes control
; from that address using a fake RTS.
; Screen should be disabled before calling this routine.
;-----------------------------------------
; Setup :
; ZP_IRQ_API_DATA_LO     = $6C
; ZP_IRQ_API_DATA_HI     = $6D
; ZP_IRQ_API_DATA_LENGTH = $6B
; ZP_IRQ_API_CALLBACK_LO = $73
; ZP_IRQ_API_CALLBACK_HI = $74
;-----------------------------------------
; Registers In  : Y - (Transfer Mode)
; Registers Out : None
;-----------------------------------------
PROT_ReceiveFragment
	JSR PROT_DisableInterrupts
	LDA NMITAB, Y
	STA SOFTNMIVECTOR	
	LDA #$80				; HIGH portion of $8000 (Cartridge ROM address)
	STA SOFTNMIVECTOR+1	

	LDA #$00
	STA ZP_IRQ_STATE_WAITHANDLE
	
	#SETBANK PP_CONFIG_DEFAULT

	LDX ZP_IRQ_API_DATA_LENGTH
   	LDY #$00				; Setup for transfer routine

	CLV						; V=0 so WAIT_TRANSFER_DONE enters the loop
	#WAIT_TRANSFER_DONE		; Spin until NMI handler marks all bytes received

	; Do a fake RTS
	LDA ZP_IRQ_API_CALLBACK_HI
	PHA
	LDA ZP_IRQ_API_CALLBACK_LO
	PHA
	RTS


; Reads/Receives content from micro. Caller supplies the target address where the data
; will be transferred. Screen should be disabled before calling this routine.
;-----------------------------------------
; Setup :
; ZP_IRQ_API_DATA_LO     = $6C
; ZP_IRQ_API_DATA_HI     = $6D
; ZP_IRQ_API_DATA_LENGTH = $6B
;-----------------------------------------
; Registers In  : Y - (Transfer Mode)
; Registers Out : A=0, carry clear (successful)
;-----------------------------------------
PROT_ReceiveFragmentNoCallback
	JSR PROT_DisableInterrupts
	LDA NMITAB, Y
	STA SOFTNMIVECTOR	
	LDA #$80				; HIGH portion of $8000 (Cartridge ROM address)
	STA SOFTNMIVECTOR+1	

	LDA #$00
	STA ZP_IRQ_STATE_WAITHANDLE
	
	#SETBANK PP_CONFIG_DEFAULT

	LDX ZP_IRQ_API_DATA_LENGTH
   	LDY #$00				; Setup for transfer routine

	CLV						; V=0 so WAIT_TRANSFER_DONE enters the loop
	#WAIT_TRANSFER_DONE		; Spin until NMI handler marks all bytes received

	LDA #0
	CLC					; Indicate successful execution (instead of using callback)
	RTS

