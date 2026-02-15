;----------------------------------------------------------------------------------------------------------
; SafeStreamImpl.s - real stream implementation (included by CartLibStream.s)
;----------------------------------------------------------------------------------------------------------
; IMPORTANT: Do NOT include CartZpMap.inc here, because CartLibStream.s already did.
;----------------------------------------------------------------------------------------------------------

;------------------------------------------
; Stream Profile Definitions
; Format: interval, chunk, delay
;------------------------------------------
STREAM_PROFILE_SAFE:
    .BYTE 32, 16, 10

STREAM_PROFILE_NORMAL:
    .BYTE 64, 32, 4

STREAM_PROFILE_FAST:
    .BYTE 64, 64, 2

; Base label for profile table (the 3 blocks are contiguous)
STREAM_PROFILES = STREAM_PROFILE_SAFE

;------------------------------------------
; Profile IDs (constants)
;------------------------------------------
STREAM_SAFE   = 0
STREAM_NORMAL = 1
STREAM_FAST   = 2

NUM_STREAM_PROFILES = 3

;------------------------------------------
; SafeStream_Impl - Stream wrapper with profile selection
;------------------------------------------
; Input:
;   A = profile ID (0=SAFE, 1=NORMAL, 2=FAST)
; Output:
;   Carry unchanged (IRQ_Stream decides).
; Modifies: A, X, Y
;------------------------------------------
SafeStream_Impl:
.if DEBUG = 1
    CMP #NUM_STREAM_PROFILES
    BCC SS_ProfileOk
    LDA #$EE
    STA $0400
    BRK
SS_ProfileOk:
.endif

    ; Compute offset = profile_id * 3
    STA ZP_SS_OFFSET
    ASL
    CLC
    ADC ZP_SS_OFFSET
    TAX

    ; Load interval/chunk/delay
    LDA STREAM_PROFILES, X
    PHA
    INX
    LDA STREAM_PROFILES, X
    PHA
    INX
    LDA STREAM_PROFILES, X
    TAY

    PLA
    TAX
    PLA

.if DEBUG = 1
    JSR SafeStream_Debug_Impl
.endif

    JSR IRQ_Stream
    RTS

;------------------------------------------
; DEBUG Mode - Parameter Validation
;------------------------------------------
.if DEBUG = 1
SafeStream_Debug_Impl:
    CMP #0
    BEQ SafeStream_Error_Interval

    CPX #0
    BEQ SafeStream_Error_Chunk

    CPY #0
    BNE SafeStream_Debug_Ok
    JMP SafeStream_Warning_Delay

SafeStream_Debug_Ok:
    RTS

SafeStream_Error_Interval:
    LDA #$01
    STA $0400
    BRK

SafeStream_Error_Chunk:
    LDA #$02
    STA $0400
    BRK

SafeStream_Warning_Delay:
    PHA
    LDA #$03
    STA $0400
    PLA
    RTS
.endif

;------------------------------------------
; CustomStream_Impl
;------------------------------------------
; Input:
;   ZP_SS_INTERVAL = interval value
;   ZP_SS_CHUNK    = chunk value
;   ZP_SS_DELAY    = delay value
;------------------------------------------
CustomStream_Impl:
    LDA ZP_SS_INTERVAL
    LDX ZP_SS_CHUNK
    LDY ZP_SS_DELAY

.if DEBUG = 1
    JSR SafeStream_Debug_Impl
.endif

    JSR IRQ_Stream
    RTS
