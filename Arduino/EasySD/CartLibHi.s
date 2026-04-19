;----------------------------------------------------------------------------------------------------------
; High level interface to the IRQHack64 cartridge.
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
; .include "CartLibCommon.s"
; .include "CartLib.s"


;------ Command Byte ------
COMMAND_READ_FILE = 78
COMMAND_OPEN_FILE = 2
COMMAND_CLOSE_FILE = 3
COMMAND_WRITE_FILE = 4
COMMAND_DELETE_FILE = 5
COMMAND_SEEK_FILE = 6
COMMAND_LONG_SEEK_FILE = 7
COMMAND_GET_INFO_FOR_FILE = 8

COMMAND_READ_DIR = 10
COMMAND_CHANGE_DIR = 11
COMMAND_DELETE_DIR = 12
COMMAND_CREATE_DIR = 13

COMMAND_SET_PORT  = 20
COMMAND_SET_IO  = 21
COMMAND_SET_SOURCE  = 22
COMMAND_INVOKE_WITH_NAME	= 23
COMMAND_INVOKE_WITH_INDEX	= 24
COMMAND_STREAM	= 25
COMMAND_NI_STREAM = 26

COMMAND_END_TALKING  = 30
COMMAND_EXIT_TO_MENU  = 31

;------ Kernal params ------
FILE_LENGTH		= $B7
FILENAME_LOW	= $BB
FILENAME_HIGH	= $BC

SOURCE_TYPE_SD  = 1
SOURCE_TYPE_HTTP  = 2
SOURCE_TYPE_FTP  = 3

SEEK_DIRECTION_START	= 0
SEEK_DIRECTION_CURRENT	= 1
SEEK_DIRECTION_END	= 2


;------------- File functions ------------

;-----------------------------------------
; Registers In : None
; Registers Used : A
; Registers Out : A (Processing status)
;-----------------------------------------
IRQ_WaitProcessing
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

IRQ_ReadErrorOrByte	
-
	LDA CARTRIDGE_BANK_VALUE	
	BEQ -						; Wait response being switched from zero to non zero value

	BPL +						; If its a non negative value than its an error
	LSR							; Put the least significant bit in the carry

-
	LDA CARTRIDGE_BANK_VALUE	
	BMI -						; Wait till the micro switches to the non zero response
	ASL                         ; Combine the least significant bit into the response
	CLC 						; Successful
	RTS
+
	SEC							; Specify error condition A register contains the error
	RTS

;-----------------------------------------
; Registers In : A (size of file name), X (high address of filename buffer), Y (low address of filename buffer)
; Registers Used : None
;-----------------------------------------
IRQ_SetName
	STA FILE_LENGTH
	STX FILENAME_LOW
	STY FILENAME_HIGH
	RTS

;-----------------------------------------
; Registers In : X (low address), Y (high address) of 0-terminated filename
; Registers Used : A, X, Y
; Registers Out : Carry set on error (too long), clear on success
; Notes : scans up to 96 chars (absolute-path mode)
;-----------------------------------------
IRQ_SetNameZ
	STX FILENAME_LOW
	STY FILENAME_HIGH
	LDY #$00
- 
	LDA (FILENAME_LOW), Y
	BEQ +
	INY
	CPY #96
	BNE -
	SEC
	RTS
+
	TYA
	STA FILE_LENGTH
	CLC
	RTS


;-----------------------------------------
; Registers In : None
; Registers Used : A, X, Y
;-----------------------------------------
IRQ_SendFileName
	LDA FILE_LENGTH
	JSR IRQ_Send	
	LDX FILE_LENGTH
	LDY #$00
-	
	LDA (FILENAME_LOW), Y
	JSR IRQ_Send
	INY
	DEX
	BNE -
	RTS

IRQ_ProcessFileCommand	.macro
	JSR IRQ_SendFileName	
	JSR IRQ_WaitProcessing	
	.endm

; Opens file for reading/writing
;-----------------------------------------
; Registers In : X (Opening mode)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_OpenFile
	LDA #COMMAND_OPEN_FILE
	JSR IRQ_Send
	TXA
	JSR IRQ_Send ;Send flags

	IRQ_ProcessFileCommand
	RTS


; Closes currently opened file
;-----------------------------------------
; Registers In : None
; Registers Used : A
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_CloseFile
	LDA #COMMAND_CLOSE_FILE
	JSR IRQ_Send
	JSR IRQ_WaitProcessing	
	RTS

; Deletes specified file
;-----------------------------------------
; Registers In : None
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_DeleteFile
	LDA #COMMAND_DELETE_FILE
	JSR IRQ_Send
	IRQ_ProcessFileCommand
	RTS

; Reads/Receives content from currently opened file. Caller supplies the target address where the data will be transferred.
; Caller supplies return address at CALLBACK_LO / CALLBACK_HI and this routine will resume control from that address using a fake RTS.
; Screen should be disabled before calling this routine. 
; An alternative : Call this routine on non visible lines (no dma) where there is enough cycles for  file i/o and data transfer.
;-----------------------------------------
; Setup : 
; IRQ_DATA_LOW = $69
; IRQ_DATA_HIGH = $6A
; IRQ_DATA_LENGTH = $6B
; IRQ_CALLBACK_LO = $80
; IRQ_CALLBACK_HI = $81
;-----------------------------------------
; Registers In  : Y - (Transfer Mode)
; Registers Out : None
;-----------------------------------------
IRQ_ReadFile	
	LDA #COMMAND_READ_FILE
	JSR IRQ_Send
	LDA IRQ_DATA_LENGTH
	JSR IRQ_Send
	JSR IRQ_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP IRQ_ReceiveFragment
	;JMP IRQ_ReceiveFragmentCH
+
	RTS
	
	
; Reads/Receives content from currently opened file. 
; Screen should be disabled before calling this routine. 
; An alternative : Call this routine on non visible lines (no dma) where there is enough cycles for  file i/o and data transfer.
;-----------------------------------------
; Setup : 
; IRQ_DATA_LOW = $69
; IRQ_DATA_HIGH = $6A
; IRQ_DATA_LENGTH = $6B
; IRQ_CALLBACK_LO = $80
; IRQ_CALLBACK_HI = $81
;-----------------------------------------
; Registers In  : Y - (Transfer Mode)
; Registers Out : None
;-----------------------------------------
IRQ_ReadFileNoCallback	
	LDA #COMMAND_READ_FILE
	JSR IRQ_Send
	LDA IRQ_DATA_LENGTH
	JSR IRQ_Send
	JSR IRQ_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP IRQ_ReceiveFragmentNoCallback	
+
	RTS	

; Seeks currently opened file with an 16 bit positive value
;-----------------------------------------
; Setup : 
; IRQ_SEEK_LOW = $69
; IRQ_SEEK_HIGH = $6A
;-----------------------------------------
; Registers In  : X (Seek direction : 0 from beginning, 1 from current position, 2 from end position)
; Registers Out : None
;-----------------------------------------
IRQ_SeekFile
	LDA #COMMAND_SEEK_FILE
	JSR IRQ_Send
	TXA
	JSR IRQ_Send
	LDA IRQ_SEEK_LOW
	JSR IRQ_Send
	LDA IRQ_SEEK_HIGH
	JSR IRQ_Send
	JSR IRQ_WaitProcessing		
	RTS


; Seeks currently opened file with an 32 bit positive value
;-----------------------------------------
; Setup : 
; IRQ_SEEK_LOW = $69
; IRQ_SEEK_HIGH = $6A
; IRQ_SEEK_UPPER_LOW = $80
; IRQ_SEEK_UPPER_HIGH = $81
;-----------------------------------------
; Registers In  : X (Seek direction : 0 from beginning, 1 from current position, 2 from end position)
; Registers Out : None
;-----------------------------------------
IRQ_LongSeekFile
	LDA #COMMAND_LONG_SEEK_FILE
	JSR IRQ_Send
	TXA
	JSR IRQ_Send
	LDA IRQ_SEEK_LOW
	JSR IRQ_Send
	LDA IRQ_SEEK_HIGH
	JSR IRQ_Send
	LDA IRQ_SEEK_UPPER_LOW
	JSR IRQ_Send
	LDA IRQ_SEEK_UPPER_HIGH
	JSR IRQ_Send	
	JSR IRQ_WaitProcessing		
	RTS	
	
; Setup : 
; IRQ_DATA_LOW = $69
; IRQ_DATA_HIGH = $6A
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

IRQ_GetInfoForFile
	LDA #COMMAND_GET_INFO_FOR_FILE
	JSR IRQ_Send
	JSR IRQ_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	LDA #$01
	STA IRQ_DATA_LENGTH
	JMP IRQ_ReceiveFragmentNoCallback	
+	
	RTS
	
	
	

; Write 32 bytes to the currently opened file.
;-----------------------------------------
; Setup : 
; IRQ_DATA_LOW = $69
; IRQ_DATA_HIGH = $6A
;-----------------------------------------
; Registers in : None
; Registers used : A, X, Y
;-----------------------------------------
IRQ_WriteFile
	LDA #COMMAND_WRITE_FILE
	JSR IRQ_Send
	JSR IRQ_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JSR IRQ_SendFragment
+
	RTS


;----------- Directory functions ----------
; Setup
; IRQ_DATA_LOW = $69
; IRQ_DATA_HIGH = $6A
; IRQ_DATA_LENGTH = $6B
; IRQ_CALLBACK_LO = $80
; IRQ_CALLBACK_HI = $81
;-----------------------------------------
; Registers in : Y (Transfer speed)
; Registers in : X (Max number of entries)
; Registers in : A (Start from index)
; Registers used : A, X, Y
;-----------------------------------------
IRQ_ReadDirectory
	PHA
	LDA #COMMAND_READ_DIR
	JSR IRQ_Send
	TXA	
	JSR IRQ_Send
	LDA IRQ_DATA_LENGTH
	JSR IRQ_Send	
	PLA
	JSR IRQ_Send		
	JSR IRQ_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP IRQ_ReceiveFragment
+	
	RTS

;----------- Directory functions ----------
; Setup
; IRQ_DATA_LOW = $69
; IRQ_DATA_HIGH = $6A
; IRQ_DATA_LENGTH = $6B
; IRQ_CALLBACK_LO = $80
; IRQ_CALLBACK_HI = $81
;-----------------------------------------
; Registers in : X (Max number of entries)
; Registers used : A, X
;-----------------------------------------
IRQ_ReadDirectoryNC
	PHA
	LDA #COMMAND_READ_DIR
	JSR IRQ_Send
	TXA	
	JSR IRQ_Send
	LDA IRQ_DATA_LENGTH
	JSR IRQ_Send	
	PLA
	JSR IRQ_Send
	JSR IRQ_WaitProcessing		

	BPL +					; Check if command is not successful, if not just return
	JMP IRQ_ReceiveFragmentNoCallback
+	
	RTS	
	
IRQ_ChangeDirectory
	LDA #COMMAND_CHANGE_DIR
	JSR IRQ_Send
	IRQ_ProcessFileCommand	
	RTS

IRQ_DeleteDirectory
	LDA #COMMAND_DELETE_DIR
	JSR IRQ_Send
	IRQ_ProcessFileCommand	
	RTS

; Caller should call IRQ_SetName to set the path to the resource
;-----------------------------------------
; Registers In : X (Reserved)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_InvokeWithName
	LDA #COMMAND_INVOKE_WITH_NAME
	JSR IRQ_Send
	TXA
	JSR IRQ_Send ;Send flags

	IRQ_ProcessFileCommand
	RTS

	
;-----------------------------------------
; Registers In : X (Order number of selected program in the current path)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_InvokeWithIndex
	LDA #COMMAND_INVOKE_WITH_INDEX
	JSR IRQ_Send
	TXA
	JSR IRQ_Send ;Send flags

	JSR IRQ_WaitProcessing		
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
IRQ_Stream
	PHA
	LDA #COMMAND_STREAM
	JSR IRQ_Send	
	PLA
	JSR IRQ_Send
	TXA
	JSR IRQ_Send 
	TYA
	JSR IRQ_Send 
	
	JSR IRQ_WaitProcessing		
	RTS	

; Sets up micro to stream content from current open file. 
; Micro sends 8 bytes for each flagging of cartridge receive port
; Receiver should hard syncronize itself to this 8 bytes.
; Receiver should send the number of 8 bytes to receive. This should not exceed 50 or else the command fails.
; Unlike normal streaming micro handles this type of streaming in the foreground and doesn't use interrupts.
; To stop streaming...[TODO]
;-----------------------------------------
; Registers In : A (8 byte fragment count)
; Registers Used : A, X, Y
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_NIStream
	PHA
	LDA #COMMAND_NI_STREAM
	JSR IRQ_Send	
	PLA
	JSR IRQ_Send
	
	JSR IRQ_WaitProcessing		
	RTS	
	
	
; Ends talking and exits to menu
;-----------------------------------------
; Registers In : None
; Registers Used : A
; Registers Out : A (Status of operation)
;-----------------------------------------	
IRQ_ExitToMenu
	LDA #COMMAND_EXIT_TO_MENU
	JSR IRQ_Send
	JSR IRQ_WaitProcessing	
	RTS	
	
;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
IRQ_DisableDisplay
	LDA VIC_CONTROL_1
	AND #$EF
	STA VIC_CONTROL_1	
	

	RTS
	
;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------	
IRQ_EnableDisplay
	LDA VIC_CONTROL_1
	ORA #VIC_DEN
	STA VIC_CONTROL_1	
	RTS	

;-----------------------------------------
; Registers In : None
; Registers Used : A
;-----------------------------------------
IRQ_EnableRasterInterrupts
	LDA #$01
	STA VIC_INT_CONTROL	;Enable raster interrupts
	RTS


;-----------------------------------------
; LoadFileBySize - Load file with exact size calculation
; Replaces hardcoded page count with size-based loading
;-----------------------------------------
; Setup (before calling):
;   IRQ_FILE_SIZE_LO/HI/U_LO/U_HI = 32-bit file size (from IRQ_GetInfoForFile)
;   IRQ_SKIP_BYTES_LO/HI = Number of bytes to skip (e.g., 2 for PRG header)
;   IRQ_DATA_LOW/HIGH = Target load address
;
; Uses zero page:
;   $80 = TEMP_FILE_SIZE_LO
;   $81 = TEMP_FILE_SIZE_HI
;   $82 = TEMP_FILE_SIZE_U_LO
;   $83 = TEMP_FILE_SIZE_U_HI
;
; Returns:
;   Carry clear if success, set if error
;-----------------------------------------
IRQ_FILE_SIZE_LO     = $80
IRQ_FILE_SIZE_HI     = $81
IRQ_FILE_SIZE_U_LO   = $82
IRQ_FILE_SIZE_U_HI   = $83
IRQ_SKIP_BYTES_LO    = $84
IRQ_SKIP_BYTES_HI    = $85
IRQ_PAYLOAD_LO       = $86
IRQ_PAYLOAD_HI       = $87

LoadFileBySize:
.if DEBUG = 1
	; DEBUG: Dump parameters before load
	JSR DEBUG_DumpAll
.endif

	; Step 1: Seek past header/skip bytes if needed
	LDA IRQ_SKIP_BYTES_LO
	ORA IRQ_SKIP_BYTES_HI
	BEQ +					; If skip == 0, don't seek

	LDA IRQ_SKIP_BYTES_LO
	STA IRQ_SEEK_LOW
	LDA IRQ_SKIP_BYTES_HI
	STA IRQ_SEEK_HIGH
	LDX #SEEK_DIRECTION_START
	JSR IRQ_SeekFile
	BCS LoadFileBySize_Error	; If error, return
+
	; Step 2: Calculate payload size = file_size - skip_bytes
	SEC
	LDA IRQ_FILE_SIZE_LO
	SBC IRQ_SKIP_BYTES_LO
	STA IRQ_PAYLOAD_LO
	LDA IRQ_FILE_SIZE_HI
	SBC IRQ_SKIP_BYTES_HI
	STA IRQ_PAYLOAD_HI

	; Step 3: Calculate page count (round up)
	; pages = (payload_lo + 255) >> 8 + payload_hi
	LDA IRQ_PAYLOAD_LO
	CLC
	ADC #$FF				; Add 255 for rounding up
	LDA IRQ_PAYLOAD_HI
	ADC #$00
	STA IRQ_DATA_LENGTH		; Store page count

	; Step 4: Read file data
	BEQ LoadFileBySize_Done		; If 0 pages, we're done
	JSR IRQ_ReadFileNoCallback
	BCS LoadFileBySize_Error

LoadFileBySize_Done:
.if DEBUG = 1
	; DEBUG: Dump first 16 bytes of loaded data
	JSR DEBUG_DumpFirst16Bytes
	LDA #$00
	JSR DEBUG_SetError
	JSR DEBUG_Break			; Optional BRK
.endif
	CLC						; Success
	RTS

LoadFileBySize_Error:
.if DEBUG = 1
	LDA #$01				; Error code 1 = LoadFileBySize failed
	JSR DEBUG_SetError
	JSR DEBUG_Break
.endif
	SEC						; Error
	RTS

