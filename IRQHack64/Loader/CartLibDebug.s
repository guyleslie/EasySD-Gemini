;===============================================
; CartLibDebug.s - DEBUG Infrastructure
;===============================================
; Provides hardware-free testing capabilities
; by dumping loader state to fixed memory area
;
; Memory Map: $1000-$10FF (256 bytes DEBUG area)
;
; Usage in VICE:
;   1. Load DEBUG build
;   2. Navigate menu, select file
;   3. In VICE monitor: m 1000 10ff
;   4. Verify all parameters
;===============================================

.if DEBUG = 1

;-----------------------------------------------
; DEBUG Memory Map ($CF00-$CF42)
; Safe location: $CE00-$CFFF is free in menu memory map
; No overlap with DIRSTACKTEMP ($FD00-$FFFF) or other buffers
;-----------------------------------------------
DEBUG_DUMP_BASE         = $CF00

DEBUG_LAST_FILENAME     = $CF00  ; 32 bytes (null-terminated filename)
DEBUG_FILE_LEN          = $CF20  ; 4 bytes (LO, HI, U_LO, U_HI)
DEBUG_SKIP_BYTES        = $CF24  ; 2 bytes (skip amount)
DEBUG_LOAD_ADDR         = $CF26  ; 2 bytes (target load address)
DEBUG_PAGES             = $CF28  ; 1 byte (calculated page count)
DEBUG_REMAINDER         = $CF29  ; 2 bytes (payload mod 256)
DEBUG_FIRST16BYTES      = $CF2B  ; 16 bytes (first bytes of loaded data)
DEBUG_TIMESTAMP         = $CF3B  ; 1 byte (frame counter at dump time)
DEBUG_ERROR_CODE        = $CF3C  ; 1 byte (0=OK, else error code)
DEBUG_STREAM_PROFILE    = $CF3D  ; 1 byte (stream profile ID: 0/1/2)
DEBUG_STREAM_INTERVAL   = $CF3E  ; 1 byte (stream interval param)
DEBUG_STREAM_CHUNK      = $CF3F  ; 1 byte (stream chunk param)
DEBUG_STREAM_DELAY      = $CF40  ; 1 byte (stream delay param)

; Sentinel value to detect debug dump
DEBUG_MAGIC             = $CF41  ; 2 bytes (should be $DE $42)

;-----------------------------------------------
; DEBUG_Init - Initialize debug area
;-----------------------------------------------
; Call once at startup to clear debug area
;-----------------------------------------------
DEBUG_Init:
	LDX #$00
	LDA #$00
-
	STA DEBUG_DUMP_BASE,X
	INX
	CPX #$FF
	BNE -

	; Write magic sentinel ($DE $42 = "DE" "B")
	LDA #$DE
	STA DEBUG_MAGIC
	LDA #$42   ; 'B' ASCII
	STA DEBUG_MAGIC+1

	RTS

;-----------------------------------------------
; DEBUG_DumpFilename - Dump current filename
;-----------------------------------------------
; Input: $06/$07 = pointer to filename (null-term)
;-----------------------------------------------
DEBUG_DumpFilename:
	LDY #$00
-
	LDA ($06),Y
	STA DEBUG_LAST_FILENAME,Y
	BEQ +				; Stop at null terminator
	INY
	CPY #31				; Max 31 chars + null
	BNE -
	LDA #$00			; Force null terminator
	STA DEBUG_LAST_FILENAME+31
+
	RTS

;-----------------------------------------------
; DEBUG_DumpFileSize - Dump file size params
;-----------------------------------------------
; Uses zero page $80-$87 (IRQ_FILE_SIZE_*, etc.)
;-----------------------------------------------
DEBUG_DumpFileSize:
	; File length (32-bit)
	LDA $80				; IRQ_FILE_SIZE_LO
	STA DEBUG_FILE_LEN
	LDA $81				; IRQ_FILE_SIZE_HI
	STA DEBUG_FILE_LEN+1
	LDA $82				; IRQ_FILE_SIZE_U_LO
	STA DEBUG_FILE_LEN+2
	LDA $83				; IRQ_FILE_SIZE_U_HI
	STA DEBUG_FILE_LEN+3

	; Skip bytes
	LDA $84				; IRQ_SKIP_BYTES_LO
	STA DEBUG_SKIP_BYTES
	LDA $85				; IRQ_SKIP_BYTES_HI
	STA DEBUG_SKIP_BYTES+1

	; Payload (calculated)
	LDA $86				; IRQ_PAYLOAD_LO
	STA DEBUG_REMAINDER
	LDA $87				; IRQ_PAYLOAD_HI
	STA DEBUG_REMAINDER+1

	RTS

;-----------------------------------------------
; DEBUG_DumpLoadAddr - Dump load address
;-----------------------------------------------
; Uses IRQ_DATA_LOW/HIGH ($69/$6A)
;-----------------------------------------------
DEBUG_DumpLoadAddr:
	LDA $69				; IRQ_DATA_LOW
	STA DEBUG_LOAD_ADDR
	LDA $6A				; IRQ_DATA_HIGH
	STA DEBUG_LOAD_ADDR+1
	RTS

;-----------------------------------------------
; DEBUG_DumpPages - Dump calculated page count
;-----------------------------------------------
; Uses IRQ_DATA_LENGTH ($6B)
;-----------------------------------------------
DEBUG_DumpPages:
	LDA $6B				; IRQ_DATA_LENGTH
	STA DEBUG_PAGES
	RTS

;-----------------------------------------------
; DEBUG_DumpFirst16Bytes - Dump loaded data
;-----------------------------------------------
; Dumps first 16 bytes from load address
; Uses IRQ_DATA_LOW/HIGH as source
;-----------------------------------------------
DEBUG_DumpFirst16Bytes:
	LDY #$00
-
	LDA ($69),Y			; Read from load address
	STA DEBUG_FIRST16BYTES,Y
	INY
	CPY #16
	BNE -
	RTS

;-----------------------------------------------
; DEBUG_DumpTimestamp - Dump current frame
;-----------------------------------------------
DEBUG_DumpTimestamp:
	LDA $A2				; KERNAL frame counter (low byte)
	STA DEBUG_TIMESTAMP
	RTS

;-----------------------------------------------
; DEBUG_SetError - Set error code
;-----------------------------------------------
; Input: A = error code
;-----------------------------------------------
DEBUG_SetError:
	STA DEBUG_ERROR_CODE
	RTS

;-----------------------------------------------
; DEBUG_DumpStreamParams - Dump stream config
;-----------------------------------------------
; Input:
;   A = profile ID
;   X = chunk
;   Y = delay
;   $88 = interval (temp storage)
;-----------------------------------------------
DEBUG_DumpStreamParams:
	STA DEBUG_STREAM_PROFILE
	STX DEBUG_STREAM_CHUNK
	STY DEBUG_STREAM_DELAY
	LDA $88				; TEMP storage for interval
	STA DEBUG_STREAM_INTERVAL
	RTS

;-----------------------------------------------
; DEBUG_DumpAll - Convenience wrapper
;-----------------------------------------------
; Dumps all common loader state
; Call after LoadFileBySize or similar
;-----------------------------------------------
DEBUG_DumpAll:
	JSR DEBUG_DumpFileSize
	JSR DEBUG_DumpLoadAddr
	JSR DEBUG_DumpPages
	JSR DEBUG_DumpTimestamp
	RTS

;-----------------------------------------------
; DEBUG_Break - Optional breakpoint
;-----------------------------------------------
; Only breaks if DEBUG_BREAK_AFTER_LOAD is set
;-----------------------------------------------
.if DEBUG_BREAK_AFTER_LOAD = 1
DEBUG_Break:
	BRK					; Halt in VICE monitor
.else
DEBUG_Break:
	RTS					; No-op
.endif

.endif  ; DEBUG = 1

;-----------------------------------------------
; Dummy stubs for non-DEBUG builds
;-----------------------------------------------
.if DEBUG = 0
DEBUG_Init              .macro
                        .endm
DEBUG_DumpFilename      .macro
                        .endm
DEBUG_DumpFileSize      .macro
                        .endm
DEBUG_DumpLoadAddr      .macro
                        .endm
DEBUG_DumpPages         .macro
                        .endm
DEBUG_DumpFirst16Bytes  .macro
                        .endm
DEBUG_DumpTimestamp     .macro
                        .endm
DEBUG_SetError          .macro
                        .endm
DEBUG_DumpStreamParams  .macro
                        .endm
DEBUG_DumpAll           .macro
                        .endm
DEBUG_Break             .macro
                        .endm
.endif
