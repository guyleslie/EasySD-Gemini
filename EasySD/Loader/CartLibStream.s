;----------------------------------------------------------------------------------------------------------
; High-level streaming interface for the IRQHack64 cartridge.
; 
; Provides routines for loading large files (>64KB) using the Arduino's
; interrupt-driven streaming mechanism (COMMAND_STREAM).
;----------------------------------------------------------------------------------------------------------


.include "CartZpMap.inc"
.include "CartLibHi.s"
.include "CartLibDebug.s"

;----------------------------------------------------------------------------------------------------------
; StreamLargeFile - Load a large file using COMMAND_STREAM
;----------------------------------------------------------------------------------------------------------
; This routine replaces LoadFileBySize for files that exceed the 16-bit size limit.
; It orchestrates the entire streaming process from the C64 side.
;
; Setup (before calling):
;   Zero Page memory must be set by the caller:
;   STREAM_TARGET_ADDR_LO/HI:   Target base address in C64 RAM.
;   STREAM_FILE_SIZE_0/1/2/3:   32-bit file size (LSB to MSB).
;
; NOTE: This routine uses ZP addresses $90-$95.
;
; Returns:
;   Carry clear if success, set if error.
;   A: Status code (0 on success).
;
;----------------------------------------------------------------------------------------------------------

; ZP addresses used by this routine.
; Allocated from CartZpMap.inc
STREAM_FILE_SIZE_0 = ZP_STREAM_API_REMAIN0
STREAM_FILE_SIZE_1 = ZP_STREAM_API_REMAIN1
STREAM_FILE_SIZE_2 = ZP_STREAM_API_REMAIN2
STREAM_FILE_SIZE_3 = ZP_STREAM_API_REMAIN3


; Hardware Interaction Ports
STREAM_TRIGGER_PORT    = $DF00 ; Reading from here pulses /IO2 to request next byte
STREAM_DATA_PORT       = $DE00 ; Cartridge data register (reads byte from Arduino)

StreamLargeFile:
    SEI                     ; Disable interrupts to ensure timing integrity
    #SAVEREGS

    ; Step 1: Copy 32-bit file size to our countdown timer
    LDA STREAM_FILE_SIZE_0
    STA ZP_STREAM_API_REMAIN0
    LDA STREAM_FILE_SIZE_1
    STA ZP_STREAM_API_REMAIN1
    LDA STREAM_FILE_SIZE_2
    STA ZP_STREAM_API_REMAIN2
    LDA STREAM_FILE_SIZE_3
    STA ZP_STREAM_API_REMAIN3

    ; Step 2: Initialize stream on Arduino
    ; The current Arduino firmware ignores these parameters, but we send them anyway for future compatibility.
    LDA #$00                ; initialDelay
    LDX #$00                ; countStreamedBytes
    LDY #$00                ; delayBetweenBytes
    JSR PROT_Stream
    BCS _stream_error       ; If carry is set, PROT_Stream failed

    LDY #$00                ; Y will be our index for (zp),y addressing

_stream_loop:
    ; Check if transfer is complete (is the 32-bit counter zero?)
    LDA ZP_STREAM_API_REMAIN0
    ORA ZP_STREAM_API_REMAIN1
    ORA ZP_STREAM_API_REMAIN2
    ORA ZP_STREAM_API_REMAIN3
    BEQ _stream_done        ; If all bytes are zero, we are done

    ; Step 3: Request and receive a byte
    LDA STREAM_TRIGGER_PORT ; Pulse /IO2 to signal Arduino to send next byte
    LDA STREAM_DATA_PORT    ; Read the byte from the cartridge port

    ; Step 4: Store the byte in memory
    STA (ZP_STREAM_API_TARGET_LO),Y

    ; Step 5: Increment target address pointer
    INC ZP_STREAM_API_TARGET_LO
    BNE +
    INC ZP_STREAM_API_TARGET_HI
+
    ; Step 6: Decrement 32-bit byte counter
    SEC
    LDA ZP_STREAM_API_REMAIN0
    SBC #$01
    STA ZP_STREAM_API_REMAIN0
    LDA ZP_STREAM_API_REMAIN1
    SBC #$00
    STA ZP_STREAM_API_REMAIN1
    LDA ZP_STREAM_API_REMAIN2
    SBC #$00
    STA ZP_STREAM_API_REMAIN2
    LDA ZP_STREAM_API_REMAIN3
    SBC #$00
    STA ZP_STREAM_API_REMAIN3

    JMP _stream_loop

_stream_done:
    ; Step 7: Finalize transfer.
    ;
    ; HARDWARE BEHAVIOR:
    ; - The Arduino SEL line (A4 pin) is configured as INPUT to monitor C64 status
    ; - The C64 CANNOT control this line (no software control possible)
    ; - Transfer termination is PASSIVE from C64 side:
    ;
    ;   Normal Exit:
    ;   1. C64 stops issuing STREAM_TRIGGER_PORT reads (no more /IO2 pulses)
    ;   2. Arduino detects 100ms timeout (STREAM_TIMEOUT_MS)
    ;   3. Arduino automatically exits streaming mode
    ;
    ;   Emergency Exit:
    ;   - If SEL line goes LOW (e.g., C64 reset/hardware event)
    ;   - Arduino immediately exits via digitalRead(SEL) check
    ;
    ; Therefore, no specific "end signal" command is needed from C64.

    ; A small delay might be good practice for stability before returning.
    NOP
    NOP

    #RESTOREREGS
    
    CLI                     ; Re-enable interrupts
    CLC                     ; Return CARRY CLEAR for success
    RTS

_stream_error:
    PLA                     ; Restore registers from stack
    TAY
    PLA
    TAX
    PLA

    CLI                     ; Re-enable interrupts
    SEC                     ; Return CARRY SET for error
    RTS