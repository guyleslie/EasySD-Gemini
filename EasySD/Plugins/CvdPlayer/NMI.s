; Fully unrolled NI receiver for one 400-byte CVD block.
; The Arduino still streams COMMAND_NI_STREAM as 50 fragments * 8 bytes.
; This uses no index registers, so X/Y foreground state survives unchanged.

NMI_000
.for offset = 0, offset < 400, offset = offset + 1
	LDA MODULATION_ADDRESS
	LDA CARTRIDGE_BANK_VALUE
	STA TRANSFERBUFFER + offset
.next
	RTS
