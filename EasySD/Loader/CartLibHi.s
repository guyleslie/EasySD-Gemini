;----------------------------------------------------------------------------------------------------------
; High level interface to the EasySD cartridge.
;----------------------------------------------------------------------------------------------------------
; This interface will deal with opening / closing files. writing / reading them and a bunch of other stuff.
; Each command to the cartridge will have
; A command byte
; <N bytes argument related to the command>
;
; A special location on cartridge rom is used to handshake and get the error status from the cartridge.
; This location is actually used to transfer stuff from cartridge to c64. Cartridge can set a value here
; between 00 and FF. There are more than one such location and its dependent on the loader on the eprom.
; One with a nifty locations is especially left for this interfaces purpose. 
; Its on $80FF and its mirrored on ($81FF, $82FF and so on)
; While cartridge is idle waiting a command this location will always reflect the value of #$00
; While its processing stuff it will have a value of #$01
; Upon performing stuff the value will reflect the error status of the operation. #$80 will be the 
; successful state.
;----------------------------------------------------------------------------------------------------------
.include "CartLib.s"


;------------- File functions ------------

;-----------------------------------------
; Registers In : None
; Registers Used : A
; Registers Out : A (Processing status)
;-----------------------------------------
PROT_WaitProcessing
.if DEBUG = 1
	; DEBUG: Skip hardware wait, return immediate success
	CLC
	RTS
.else
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
-
	LDA CARTRIDGE_BANK_VALUE
	BEQ -
	BPL +
	CLC
	RTS
+
	SEC
	RTS
.endif


; Used to retrieve error status along with a one byte response
; Like normal commands CARTRIDGE_BANK_VALUE initially set as 0 by the micro
; When the processing is done, cartridge sets this value to a 1-$7F for error response.
; If there is no error than the low byte of response is encoded in the successful response 
; which would be B1xxxxxxV where V is the least significant bit of the response.
; Then c64 would read another value from the CARTRIDGE_BANK_VALUE that is positive in the form B0VVVVVVV
; Where VVVVVVV is the most significant 7 bits of the response.
; This is (I hope) is simpler than triggering an nmi interrupt and setting a bank value for response.

PROT_ReadErrorOrByte	
-
	LDA CARTRIDGE_BANK_VALUE	
	BEQ -						; Wait response being switched from zero to non zero value

	BPL +						; If its a non negative value than its an error
	LSR						; Put the least significant bit in the carry

-
	LDA CARTRIDGE_BANK_VALUE	
	BMI -						; Wait till the micro switches to the non zero response
	ASL                                             ; Combine the least significant bit into the response
	CLC 						; Successful
	RTS
+
	SEC						; Specify error condition A register contains the error
	RTS

;-----------------------------------------
; Registers In : A (size of file name), X (high address of filename buffer), Y (low address of filename buffer)
; Registers Used : None
;-----------------------------------------
PROT_SetName
	STA KERNAL_FILENAME_LENGTH
	STX KERNAL_FILENAME_LOW
	STY KERNAL_FILENAME_HIGH
	RTS

;-----------------------------------------
; Registers In : X (low address), Y (high address) of a 0-terminated filename
; Registers Used : A, X, Y
; Registers Out : Carry clear = success, set = unterminated string
;-----------------------------------------
PROT_SetNameZ
	STX $06
	STY $07
	LDY #$00
-
	LDA ($06), Y
	BEQ +
	INY
	BNE -
	SEC
	RTS
+
	TYA
	PHA
	LDX $06
	LDY $07
	PLA
	JSR PROT_SetName
	CLC
	RTS

;-----------------------------------------
; Registers In : None
; Registers Used : A, X, Y
;-----------------------------------------
PROT_SendFileName
	LDA KERNAL_FILENAME_LENGTH
	JSR PROT_Send	
	LDX KERNAL_FILENAME_LENGTH
	LDY #$00
-	
	LDA (KERNAL_FILENAME_LOW), Y
	JSR PROT_Send
	INY
	DEX
	BNE -
	RTS

PROT_ProcessFileCommand	.macro
	JSR PROT_SendFileName	
	JSR PROT_WaitProcessing	
	.endm

; Opens file for reading/writing
;-----------------------------------------
; Registers In : X (Opening mode)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_OpenFile
	LDA #COMMAND_OPEN_FILE
	JSR PROT_Send
	TXA
	JSR PROT_Send ;Send flags

	PROT_ProcessFileCommand
	RTS


; Closes currently opened file
;-----------------------------------------
; Registers In : None
; Registers Used : A
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_CloseFile
	LDA #COMMAND_CLOSE_FILE
	JSR PROT_Send
	JSR PROT_WaitProcessing	
	RTS

; Deletes specified file
;-----------------------------------------
; Registers In : None
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_DeleteFile
	LDA #COMMAND_DELETE_FILE
	JSR PROT_Send
	PROT_ProcessFileCommand
	RTS

; Reads/Receives content from currently opened file. Caller supplies the target address where the data will be transferred.
; Caller supplies return address at CALLBACK_LO / CALLBACK_HI and this routine will resume control from that address using a fake RTS.
; Screen should be disabled before calling this routine. 
; An alternative : Call this routine on non visible lines (no dma) where there is enough cycles for  file i/o and data transfer.
;-----------------------------------------
; Setup : 
; ZP_IRQ_API_DATA_LO = $6C
; ZP_IRQ_API_DATA_HI = $6D
; ZP_IRQ_API_DATA_LENGTH = $6B
; ZP_IRQ_API_CALLBACK_LO = $73
; ZP_IRQ_API_CALLBACK_HI = $74
;-----------------------------------------
; Registers In  : Y - (Transfer Mode)
; Registers Out : None
;-----------------------------------------
PROT_ReadFile	
	LDA #COMMAND_READ_FILE
	JSR PROT_Send
	LDA ZP_IRQ_API_DATA_LENGTH
	JSR PROT_Send
	JSR PROT_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP PROT_ReceiveFragment
	;JMP PROT_ReceiveFragmentCH
+
	RTS
	
	
; Reads/Receives content from currently opened file. 
; Screen should be disabled before calling this routine. 
; An alternative : Call this routine on non visible lines (no dma) where there is enough cycles for  file i/o and data transfer.
;-----------------------------------------
; Setup : 
; ZP_IRQ_API_DATA_LO = $6C
; ZP_IRQ_API_DATA_HI = $6D
; ZP_IRQ_API_DATA_LENGTH = $6B
; ZP_IRQ_API_CALLBACK_LO = $73
; ZP_IRQ_API_CALLBACK_HI = $74
;-----------------------------------------
; Registers In  : Y - (Transfer Mode)
; Registers Out : None
;-----------------------------------------
PROT_ReadFileNoCallback	
	LDA #COMMAND_READ_FILE
	JSR PROT_Send
	LDA ZP_IRQ_API_DATA_LENGTH
	JSR PROT_Send
	JSR PROT_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP PROT_ReceiveFragmentNoCallback	
+
	RTS	

; Seeks currently opened file with an 16 bit positive value
;-----------------------------------------
; Setup : 
; ZP_IRQ_API_SEEK_LO = $69
; ZP_IRQ_API_SEEK_HI = $6A
;-----------------------------------------
; Registers In  : X (Seek direction : 0 from beginning, 1 from current position, 2 from end position)
; Registers Out : None
;-----------------------------------------
PROT_SeekFile
	LDA #COMMAND_SEEK_FILE
	JSR PROT_Send
	TXA
	JSR PROT_Send
	LDA ZP_IRQ_API_SEEK_LO
	JSR PROT_Send
	LDA ZP_IRQ_API_SEEK_HI
	JSR PROT_Send
	JSR PROT_WaitProcessing		
	RTS


; Seeks currently opened file with an 32 bit positive value
;-----------------------------------------
; Setup : 
; ZP_IRQ_API_SEEK_LO = $69
; ZP_IRQ_API_SEEK_HI = $6A
; ZP_IRQ_API_SEEK_UPPER_LO = $75
; ZP_IRQ_API_SEEK_UPPER_HI = $76
;-----------------------------------------
; Registers In  : X (Seek direction : 0 from beginning, 1 from current position, 2 from end position)
; Registers Out : None
;-----------------------------------------
PROT_LongSeekFile
	LDA #COMMAND_LONG_SEEK_FILE
	JSR PROT_Send
	TXA
	JSR PROT_Send
	LDA ZP_IRQ_API_SEEK_LO
	JSR PROT_Send
	LDA ZP_IRQ_API_SEEK_HI
	JSR PROT_Send
	LDA ZP_IRQ_API_SEEK_UPPER_LO
	JSR PROT_Send
	LDA ZP_IRQ_API_SEEK_UPPER_HI
	JSR PROT_Send	
	JSR PROT_WaitProcessing		
	RTS	
	
; Setup : 
; ZP_IRQ_API_DATA_LO = $69
; ZP_IRQ_API_DATA_HI = $6A
; Gets 256 byte data, first 32 bytes contain directoryEntry.
;  uint8_t  name[11];
;  uint8_t  attributes;
;  uint8_t  reservedNT;
;  uint8_t  creationTimeTenths;
;  /** Time file was created. */
;  uint16_t creationTime;
;  /** Date file was created. */
;  uint16_t creationDate;
;  uint16_t lastAccessDate;
;  uint16_t firstClusterHigh;
;  uint16_t firstClusterHigh;
;  /** Time of last write. File creation is considered a write. */
;  uint16_t lastWriteTime;
;  /** Date of last write. File creation is considered a write. */
;  uint16_t lastWriteDate;
;  /** Low word of this entry's first cluster number. */
;  uint16_t firstClusterLow;
;  /** 32-bit unsigned holding this file's size in bytes. */
;  uint32_t fileSize;
; -------------------------------------------------------------
; The most interesting and useful thing here is the fileSize of course.

PROT_GetInfoForFile
	LDA #COMMAND_GET_INFO_FOR_FILE
	JSR PROT_Send
	JSR PROT_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	LDA #$01
	STA ZP_IRQ_API_DATA_LENGTH
	JMP PROT_ReceiveFragmentNoCallback	
+	
	RTS
	
	
	

; Write 32 bytes to the currently opened file.
;-----------------------------------------
; Setup : 
; ZP_IRQ_API_DATA_LO = $6C
; ZP_IRQ_API_DATA_HI = $6D
;-----------------------------------------
; Registers in : None
; Registers used : A, X, Y
;-----------------------------------------
PROT_WriteFile		LDA #COMMAND_WRITE_FILE
	JSR PROT_Send
	JSR PROT_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JSR PROT_SendFragment
+
	RTS


;----------- Directory functions ----------
; Setup
; ZP_IRQ_API_DATA_LO = $6C
; ZP_IRQ_API_DATA_HI = $6D
; ZP_IRQ_API_DATA_LENGTH = $6B
; ZP_IRQ_API_CALLBACK_LO = $73
; ZP_IRQ_API_CALLBACK_HI = $74
;-----------------------------------------
; Registers in : Y (Transfer speed)
; Registers in : X (Max number of entries)
; Registers in : A (Start from index)
; Registers used : A, X, Y
;-----------------------------------------
PROT_ReadDirectory		PHA
	LDA #COMMAND_READ_DIR
	JSR PROT_Send
	TXA	
	JSR PROT_Send
	LDA ZP_IRQ_API_DATA_LENGTH
	JSR PROT_Send	
	PLA
	JSR PROT_Send		
	JSR PROT_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP PROT_ReceiveFragment
+	
	RTS

;----------- Directory functions ----------
; Setup
; ZP_IRQ_API_DATA_LO = $6C
; ZP_IRQ_API_DATA_HI = $6D
; ZP_IRQ_API_DATA_LENGTH = $6B
; ZP_IRQ_API_CALLBACK_LO = $73
; ZP_IRQ_API_CALLBACK_HI = $74
;-----------------------------------------
; Registers in : X (Max number of entries)
; Registers used : A, X
;-----------------------------------------
PROT_ReadDirectoryNC		PHA
	LDA #COMMAND_READ_DIR
	JSR PROT_Send
	TXA	
	JSR PROT_Send
	LDA ZP_IRQ_API_DATA_LENGTH
	JSR PROT_Send	
	PLA
	JSR PROT_Send
	JSR PROT_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP PROT_ReceiveFragmentNoCallback
+	
	RTS	
	
PROT_ChangeDirectory
	LDA #COMMAND_CHANGE_DIR
	JSR PROT_Send
	PROT_ProcessFileCommand	
	RTS

;-----------------------------------------
; Registers In : A (page index), X (row index on current page)
; Registers Used : A, X
; Registers Out : A (Status of operation)
;-----------------------------------------
PROT_ChangeDirectoryIndex
	PHA
	LDA #COMMAND_CHANGE_DIR_INDEX
	JSR PROT_Send
	PLA
	JSR PROT_Send
	TXA
	JSR PROT_Send
	JSR PROT_WaitProcessing
	RTS

PROT_DeleteDirectory
	LDA #COMMAND_DELETE_DIR
	JSR PROT_Send
	PROT_ProcessFileCommand	
	RTS


;----------- Other functions ----------


;-----------------------------------------
; Registers in : A (low most 2 bits A9-A8 of address) X (A7-A0 part of address)
; Registers used : A, X
;-----------------------------------------
PROT_SeekEeprom	
	PHA
	LDA #COMMAND_SEEK_EEPROM	
	JSR PROT_Send
	PLA
	JSR PROT_Send	
	TXA
	JSR PROT_Send
	JSR PROT_WaitProcessing	
	RTS

; Eeprom is read from the last address that is set by PROT_SeekEeprom
; Micro increases the location by 1 wrapping at the end of the address space for eeprom
;-----------------------------------------
; Registers in : None
; Registers used : A
;-----------------------------------------
PROT_ReadEeprom
	LDA #COMMAND_READ_EEPROM
	JSR PROT_Send
	JSR PROT_ReadErrorOrByte
	RTS

;-----------------------------------------
; Registers in : X (Value to write to Eeprom)
; Registers used : A
;-----------------------------------------
PROT_WriteEeprom
	LDA #COMMAND_WRITE_EEPROM
	JSR PROT_Send
	TXA
	JSR PROT_Send
	JSR PROT_WaitProcessing		
	RTS


; Caller should call PROT_SetName to set the path to the resource
;-----------------------------------------
; Registers In : X (Reserved)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_InvokeWithName
	LDA #COMMAND_INVOKE_WITH_NAME
	JSR PROT_Send
	TXA
	JSR PROT_Send ;Send flags

	PROT_ProcessFileCommand
	RTS

	
;-----------------------------------------
; Registers In : X (Order number of selected program in the current path)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_InvokeWithIndex
	LDA #COMMAND_INVOKE_WITH_INDEX
	JSR PROT_Send
	TXA
	JSR PROT_Send ;Send flags

	JSR PROT_WaitProcessing		
	RTS	

	
; Sets up micro to stream content from current open file. 
; 1. With the first command to micro it fills it's internal buffer
; 2. Waits for the receiver to send an interrupt for it's first streaming.
; 3. It streams bytes for each interrupt it receives. It refills its buffer when "forced buffered read interval" times data is streamed. 
; 4. Upon receiving "forced buffered read interval" chunks receiver should wait for the sender's buffer to refill.
;-----------------------------------------
; Registers In : A (forced buffered read interval), X (Count of streamed bytes per chunk), Y (Microsecond delay between each byte)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_Stream
	PHA
	LDA #COMMAND_STREAM
	JSR PROT_Send	
	PLA
	JSR PROT_Send
	TXA
	JSR PROT_Send 
	TYA
	JSR PROT_Send 
	
	JSR PROT_WaitProcessing		
	RTS	

; Starts non-interrupted (NI) streaming from the currently open file.
; The micro sends data in bursts of (A * 8) bytes, synchronized to IO2 strobes
; driven by the C64 receiver (e.g. via NMI handlers). The micro runs this in
; the foreground with all interrupts disabled for maximum throughput.
;
; Fragment count controls the per-iteration buffer size only, NOT total frames.
; Streaming continues indefinitely until the C64 drives the SEL (GAME) line low.
; To stop: call PROT_ExitToMenu, which resets the cartridge interface via SEL.
; There is no partial-transfer stop — this is by design for real-time streaming.
;
; Max fragment count: 50 (= 400 bytes per burst). Larger values are rejected.
;-----------------------------------------
; Registers In : A (8-byte fragment count, 1..50)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------
PROT_NIStream
	PHA
	LDA #COMMAND_NI_STREAM
	JSR PROT_Send	
	PLA
	JSR PROT_Send
	
	JSR PROT_WaitProcessing		
	RTS	
	
	
; Ends talking and exits to menu
;-----------------------------------------
; Registers In : None
; Registers Used : A
; Registers Out : A (Status of operation)
;-----------------------------------------	
PROT_ExitToMenu
	LDA #COMMAND_EXIT_TO_MENU
	JSR PROT_Send
	JSR PROT_WaitProcessing	
	RTS	
	
;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
PROT_DisableDisplay
	LDA VIC_CONTROL_1
	AND #$EF
	STA VIC_CONTROL_1	
	

	RTS
	
;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
PROT_EnableDisplay
	LDA VIC_CONTROL_1
	ORA #VIC_DEN
	STA VIC_CONTROL_1	
	RTS	

;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------
PROT_EnableRasterInterrupts
	LDA #$01
	STA VIC_INT_CONTROL	;Enable raster interrupts
	RTS


;-----------------------------------------
; LoadFileBySize - Load file with exact size calculation
; Replaces hardcoded page count with size-based loading
;-----------------------------------------
; Setup (before calling):
;   ZP_LOADFILE_API_SIZE0/1/2/3 = 32-bit file size (from PROT_GetInfoForFile)
;   ZP_LOADFILE_API_SKIP_LO/HI = Number of bytes to skip (e.g., 2 for PRG header)
;   ZP_IRQ_API_DATA_LO/HIGH = Target load address
;
; Returns:
;   Carry clear if success, set if error
;-----------------------------------------


LoadFileBySize:
.if DEBUG = 1
	; DEBUG: Dump parameters before load
	JSR DEBUG_DumpAll
.endif

	; Step 1: Seek past header/skip bytes if needed
	LDA ZP_LOADFILE_API_SKIP_LO
	ORA ZP_LOADFILE_API_SKIP_HI
	BEQ +					; If skip == 0, don't seek

	LDA ZP_LOADFILE_API_SKIP_LO
	STA ZP_IRQ_API_SEEK_LO
	LDA ZP_LOADFILE_API_SKIP_HI
	STA ZP_IRQ_API_SEEK_HI
	LDX #SEEK_DIRECTION_START
	JSR PROT_SeekFile
	BCS LoadFileBySize_Error	        ; If error, return
+
	; Step 2: Calculate payload size = file_size - skip_bytes
	; WARNING: This is a 16-bit subtraction. It ignores the upper 16 bits of the
	; file size (ZP_LOADFILE_API_SIZE2/3). This limits the loadable size to
	; less than 64KB. For larger files, the payload size will be incorrect.
	SEC
	LDA ZP_LOADFILE_API_SIZE0
	SBC ZP_LOADFILE_API_SKIP_LO
	STA ZP_LOADFILE_API_PAYLOAD_LO
	LDA ZP_LOADFILE_API_SIZE1
	SBC ZP_LOADFILE_API_SKIP_HI
	STA ZP_LOADFILE_API_PAYLOAD_HI

	; Step 3: Calculate page count (round up)
	; pages = (payload_lo + 255) >> 8 + payload_hi
	LDA ZP_LOADFILE_API_PAYLOAD_LO
	CLC
	ADC #$FF				; Add 255 for rounding up
	LDA ZP_LOADFILE_API_PAYLOAD_HI
	ADC #$00
	STA ZP_IRQ_API_DATA_LENGTH		; Store page count

	; Step 4: Read file data
	BEQ LoadFileBySize_Done		        ; If 0 pages, we're done
	JSR PROT_ReadFileNoCallback
	BCS LoadFileBySize_Error

LoadFileBySize_Done:
.if DEBUG = 1
	; DEBUG: Dump first 16 bytes of loaded data
	JSR DEBUG_DumpFirst16Bytes
	LDA #$00
	JSR DEBUG_SetError
	JSR DEBUG_Break			        ; Optional BRK
.endif
	CLC					; Success
	RTS

LoadFileBySize_Error:
.if DEBUG = 1
	LDA #$01				; Error code 1 = LoadFileBySize failed
	JSR DEBUG_SetError
	JSR DEBUG_Break
.endif
	SEC					; Error
	RTS