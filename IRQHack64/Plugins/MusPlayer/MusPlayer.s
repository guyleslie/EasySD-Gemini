;============================================================
; EasySD / IRQHack64 - MUS Player Plugin
;============================================================
; Plays Compute! Enhanced SID Player .MUS files.
;
; Supports BOTH:
;   - RAW .MUS (no PRG load header)
;   - PRG-wrapped .MUS (2-byte load address header)
;
; Recommended for this project:
;   - Keep this plugin small (it runs at $C000 in the plugin window)
;   - Load the SID player as a separate file from SD: SIDPLAYER.PRG
;     IMPORTANT: SIDPLAYER.PRG must be assembled for base $9000.
;   - Load selected .MUS into $8000, auto-detect skip 0/2.
;   - Start playback using player entry points.
;
; File naming:
;   The menu builds plugin name from extension + 'PLUGIN.PRG'
;   So for '.MUS' selection, the SD must contain: MUSPLUGIN.PRG
;
;============================================================

.enc "screen"

; Music + player addresses
SONG_ADDRESS   = $8000
PLAYER_ADDRESS = $9000

;------------------------------------------------------------
; DEBUG macros
;------------------------------------------------------------

.include "../../Loader/DebugMacros.s"

* = $C000

MusPluginEntry:
    jmp PluginMain          ; Keep for compatibility

;------------------------------------------------------------
; PluginMain - nieuw 5.txt standard entry point
;------------------------------------------------------------
PluginMain:
    jsr SAVESTATE          ; Save VIC/$01 state for clean menu return
    jsr Plugin_Init
    bcs Plugin_Exit         ; Init failed
    jsr Plugin_Run
Plugin_Exit:
    jsr Plugin_Shutdown
    jsr RESTORESTATE       ; Restore VIC/$01 state for clean menu return
    jsr IRQ_DisableDisplay
    jsr IRQ_ExitToMenu
    jmp *

;------------------------------------------------------------
; Plugin_Run - Main plugin logic
;------------------------------------------------------------
Plugin_Run:
    ; 1) Load external SID player (SIDPLAYER.PRG) into $9000
    jsr LoadSidPlayer9000
    jsr ERROR_GATE

    ; 2) Load selected MUS into $8000 (skip 0/2 autodetect)
    jsr LoadSelectedMus8000
    jsr ERROR_GATE

    ; 3) Start player + song
    lda #1
    sta PLAYBACK_ACTIVE     ; Mark playback as active

    jsr PLAYER_INSTALL
    jsr EnableCIA1TimerAInterrupt

    ldx #<SONG_ADDRESS
    ldy #>SONG_ADDRESS
    jsr PLAYER_INIT_SONG

    lda #%00000111
    sta PLAYER_SID_STATUS

    ; 4) Playback loop - wait for key press
PlayLoop:
    jsr GETIN
    beq PlayLoop
    cmp #$20                ; SPACE
    beq StopAndExit
    cmp #$03                ; STOP (RUN/STOP key)
    beq StopAndExit
    jmp PlayLoop

StopAndExit:
    ; Plugin_Shutdown will handle all cleanup
    clc                     ; Success
    rts

;------------------------------------------------------------
; ERROR_GATE - Centralized error handling
;------------------------------------------------------------
ERROR_GATE:
    bcc +
    jmp Run_Fail
+
    rts

Run_Fail:
    sec                     ; Error flag
    rts

;------------------------------------------------------------
; LoadSidPlayer9000
;   Opens SIDPLAYER.PRG, loads payload to $9000, closes file.
;   Assumes PRG header present -> skip 2.
;------------------------------------------------------------
LoadSidPlayer9000:
    ; set name
    ldx #<SidPlayerName
    ldy #>SidPlayerName
    lda #SIDPLAYER_NAME_LEN
    jsr IRQ_SetName

    ldx #$01
    jsr IRQ_OpenFile
    bcs LoadSid_Fail
    lda #1
    sta FILE_OPENED         ; Track open file

    ; read first page to HdrPage so we can ask GetInfo and have a buffer
    lda #<HdrPage
    sta ZP_IRQ_DATA_LOW
    lda #>HdrPage
    sta ZP_IRQ_DATA_HIGH
    lda #$01
    sta ZP_IRQ_DATA_LENGTH
    jsr IRQ_ReadFileNoCallback
    bcs LoadSid_FailClose

    ; get directory entry and size
    lda #<HdrPage
    sta ZP_IRQ_DATA_LOW
    lda #>HdrPage
    sta ZP_IRQ_DATA_HIGH
    ldy #$00
    jsr IRQ_GetInfoForFile
    bcs LoadSid_FailClose

    lda HdrPage+28
    sta ZP_LF_SIZE0
    lda HdrPage+29
    sta ZP_LF_SIZE1
    lda HdrPage+30
    sta ZP_LF_SIZE2
    lda HdrPage+31
    sta ZP_LF_SIZE3

    lda #$02
    sta ZP_LF_SKIP_LO
    lda #$00
    sta ZP_LF_SKIP_HI

    lda #<PLAYER_ADDRESS
    sta ZP_IRQ_DATA_LOW
    lda #>PLAYER_ADDRESS
    sta ZP_IRQ_DATA_HIGH
    jsr LoadFileBySize
    bcs LoadSid_FailClose

    jsr IRQ_CloseFile
    lda #0
    sta FILE_OPENED         ; File closed
    clc
    rts

LoadSid_FailClose:
    jsr IRQ_CloseFile
    lda #0
    sta FILE_OPENED         ; File closed (even on error)
LoadSid_Fail:
    sec
    rts

;------------------------------------------------------------
; LoadSelectedMus8000
;   Opens selected file name (FILENAME), loads MUS payload to $8000.
;------------------------------------------------------------
LoadSelectedMus8000:
    ldx #<CASSETTEBUFFER
    ldy #>CASSETTEBUFFER
    lda #31
    jsr IRQ_SetName

    ldx #$01
    jsr IRQ_OpenFile
    bcs LoadMus_Fail
    lda #1
    sta FILE_OPENED         ; Track open file

    ; read first page for header sniffing
    lda #<HdrPage
    sta ZP_IRQ_DATA_LOW
    lda #>HdrPage
    sta ZP_IRQ_DATA_HIGH
    lda #$01
    sta ZP_IRQ_DATA_LENGTH
    jsr IRQ_ReadFileNoCallback
    bcs LoadMus_FailClose

    ; get file info / size
    lda #<HdrPage
    sta ZP_IRQ_DATA_LOW
    lda #>HdrPage
    sta ZP_IRQ_DATA_HIGH
    ldy #$00
    jsr IRQ_GetInfoForFile
    bcs LoadMus_FailClose

    lda HdrPage+28
    sta ZP_LF_SIZE0
    lda HdrPage+29
    sta ZP_LF_SIZE1
    lda HdrPage+30
    sta ZP_LF_SIZE2
    lda HdrPage+31
    sta ZP_LF_SIZE3

    jsr DetectMusHeaderSetSkip
    bcs LoadMus_FailClose

    lda #<SONG_ADDRESS
    sta ZP_IRQ_DATA_LOW
    lda #>SONG_ADDRESS
    sta ZP_IRQ_DATA_HIGH
    jsr LoadFileBySize
    bcs LoadMus_FailClose

    jsr IRQ_CloseFile
    lda #0
    sta FILE_OPENED         ; File closed
    clc
    rts

LoadMus_FailClose:
    jsr IRQ_CloseFile
    lda #0
    sta FILE_OPENED         ; File closed (even on error)
LoadMus_Fail:
    sec
    rts

;------------------------------------------------------------
; DetectMusHeaderSetSkip
;   Uses HdrPage[0..7] and IRQ_FILE_SIZE_*.
;   Tries PRG+MUS (skip=2) then RAW (skip=0).
;------------------------------------------------------------
DetectMusHeaderSetSkip:
    jsr ValidateMusHeader_PRG
    bcc DMH_IsPrg
    jsr ValidateMusHeader_RAW
    bcc DMH_IsRaw
    sec
    rts

DMH_IsPrg:
    lda #$02
    sta ZP_LF_SKIP_LO
    lda #$00
    sta ZP_LF_SKIP_HI
    clc
    rts

DMH_IsRaw:
    lda #$00
    sta ZP_LF_SKIP_LO
    sta ZP_LF_SKIP_HI
    clc
    rts

; Scratch (in plugin RAM, not ZP)
ScratchSizeLo = Scratch0
ScratchSizeHi = Scratch1
ScratchTotLo  = Scratch2
ScratchTotHi  = Scratch3

Scratch0: .byte 0
Scratch1: .byte 0
Scratch2: .byte 0
Scratch3: .byte 0

; Validate PRG header at offset 2. Compare (6 + v1+v2+v3) <= (file_size - 2)
ValidateMusHeader_PRG:
    lda ZP_LF_SIZE2
    ora ZP_LF_SIZE3
    bne VMHPRG_Fail

    lda ZP_LF_SIZE0
    sec
    sbc #$02
    sta ScratchSizeLo
    lda ZP_LF_SIZE1
    sbc #$00
    sta ScratchSizeHi
    bcc VMHPRG_Fail

    ; require at least 8 bytes total (PRG+MUS header)
    lda ScratchSizeHi
    bne VMHPRG_OkLen
    lda ScratchSizeLo
    cmp #$08
    bcc VMHPRG_Fail
VMHPRG_OkLen:
    ; total = v1len(word at +2) + v2len(+4) + v3len(+6) + 6
    lda HdrPage+2
    sta ScratchTotLo
    lda HdrPage+3
    sta ScratchTotHi

    lda HdrPage+4
    clc
    adc ScratchTotLo
    sta ScratchTotLo
    lda HdrPage+5
    adc ScratchTotHi
    sta ScratchTotHi

    lda HdrPage+6
    clc
    adc ScratchTotLo
    sta ScratchTotLo
    lda HdrPage+7
    adc ScratchTotHi
    sta ScratchTotHi

    lda ScratchTotLo
    clc
    adc #$06
    sta ScratchTotLo
    lda ScratchTotHi
    adc #$00
    sta ScratchTotHi

    ; compare total <= size
    lda ScratchTotHi
    cmp ScratchSizeHi
    bcc VMHPRG_Pass
    bne VMHPRG_Fail
    lda ScratchTotLo
    cmp ScratchSizeLo
    bcc VMHPRG_Pass
    beq VMHPRG_Pass
VMHPRG_Fail:
    sec
    rts
VMHPRG_Pass:
    clc
    rts

; Validate RAW header at offset 0. Compare (6 + v1+v2+v3) <= file_size
ValidateMusHeader_RAW:
    lda ZP_LF_SIZE2
    ora ZP_LF_SIZE3
    bne VMHRAW_Fail

    lda ZP_LF_SIZE0
    sta ScratchSizeLo
    lda ZP_LF_SIZE1
    sta ScratchSizeHi

    ; require at least 6 bytes
    lda ScratchSizeHi
    bne VMHRAW_OkLen
    lda ScratchSizeLo
    cmp #$06
    bcc VMHRAW_Fail
VMHRAW_OkLen:
    lda HdrPage+0
    sta ScratchTotLo
    lda HdrPage+1
    sta ScratchTotHi

    lda HdrPage+2
    clc
    adc ScratchTotLo
    sta ScratchTotLo
    lda HdrPage+3
    adc ScratchTotHi
    sta ScratchTotHi

    lda HdrPage+4
    clc
    adc ScratchTotLo
    sta ScratchTotLo
    lda HdrPage+5
    adc ScratchTotHi
    sta ScratchTotHi

    lda ScratchTotLo
    clc
    adc #$06
    sta ScratchTotLo
    lda ScratchTotHi
    adc #$00
    sta ScratchTotHi

    lda ScratchTotHi
    cmp ScratchSizeHi
    bcc VMHRAW_Pass
    bne VMHRAW_Fail
    lda ScratchTotLo
    cmp ScratchSizeLo
    bcc VMHRAW_Pass
    beq VMHRAW_Pass
VMHRAW_Fail:
    sec
    rts
VMHRAW_Pass:
    clc
    rts

;------------------------------------------------------------
; EnableCIA1TimerAInterrupt
;   Defensive: menu may have disabled CIA IRQ sources before plugin run.
;------------------------------------------------------------
EnableCIA1TimerAInterrupt:
    sei
    lda #$7F
    sta $DC0D
    lda $DC0D

    lda #$01
    sta $DC0D

    lda PLAYER_DATA_CIA_TIMER_A_LO
    sta $DC04
    lda PLAYER_DATA_CIA_TIMER_A_HI
    sta $DC05

    lda #$11
    sta $DC0E
    cli
    rts

Plugin_Init:
    ; Initialize plugin (nieuw 5.txt standard)
    jsr IRQ_StartTalking    ; Correct API (NOT CartLibInit!)

    ; Initialize state flags
    lda #0
    sta PLAYBACK_ACTIVE     ; Playback not started yet
    sta FILE_OPENED         ; No file open

    clc                     ; Success
    rts

;------------------------------------------------------------
; Plugin_Shutdown - Clean shutdown (nieuw 5.txt standard)
;------------------------------------------------------------
; Always safe to call, even multiple times.
; Handles cleanup on both normal exit and error exit.
;------------------------------------------------------------
Plugin_Shutdown:
    ; 1. Stop playback if active
    lda PLAYBACK_ACTIVE
    beq +                   ; Not playing, skip
    lda #$00
    sta PLAYER_SID_STATUS   ; Stop SID voices
    jsr PLAYER_HUSH         ; Silence all voices
    jsr PLAYER_REMOVE       ; Remove player IRQ handler
    lda #0
    sta PLAYBACK_ACTIVE     ; Clear flag
+

    ; 2. Close file if open
    lda FILE_OPENED
    beq +                   ; No file open, skip
    jsr IRQ_CloseFile
    lda #0
    sta FILE_OPENED         ; Clear flag
+

    ; 3. Disable CIA Timer A
    sei
    lda #$7F
    sta $DC0D               ; Disable all CIA1 interrupts
    lda $DC0D               ; Acknowledge pending interrupts
    cli

    ; 4. End cartridge communication
    jsr IRQ_EndTalking

    rts

;------------------------------------------------------------
; Data
;------------------------------------------------------------

; State flags for clean shutdown (nieuw 5.txt standard)
PLAYBACK_ACTIVE:
    .byte 0                 ; 1 = playback active, 0 = stopped

FILE_OPENED:
    .byte 0                 ; 1 = file open, 0 = closed

SidPlayerName:
    .text "SIDPLAYER.PRG"

; 256-byte scratch for reads/GetInfo
HdrPage:
    .fill 256, 0

;------------------------------------------------------------
; Player symbols (filled for base $9000)
;------------------------------------------------------------

;------------------------------------------------------------
; Clean return helpers (shared pattern with Koala/Petscii)
;------------------------------------------------------------
FORCEIO
    lda $01
    ora #$04                ; Ensure I/O visible ($D000-$DFFF)
    sta $01
    rts

SAVESTATE
    lda $01
    sta SAVED_01
    lda $DD00
    sta SAVED_DD00
    lda $D011
    sta SAVED_D011
    lda $D016
    sta SAVED_D016
    lda $D018
    sta SAVED_D018
    lda $D020
    sta SAVED_D020
    lda $D021
    sta SAVED_D021
    lda $D022
    sta SAVED_D022
    lda $D023
    sta SAVED_D023
    rts

RESTORESTATE
    jsr FORCEIO
    lda SAVED_01
    sta $01
    lda SAVED_DD00
    sta $DD00
    lda SAVED_D018
    sta $D018
    lda SAVED_D016
    sta $D016
    lda SAVED_D011
    sta $D011
    lda SAVED_D020
    sta $D020
    lda SAVED_D021
    sta $D021
    lda SAVED_D022
    sta $D022
    lda SAVED_D023
    sta $D023
    rts

SAVED_01:   .byte 0
SAVED_DD00: .byte 0
SAVED_D011: .byte 0
SAVED_D016: .byte 0
SAVED_D018: .byte 0
SAVED_D020: .byte 0
SAVED_D021: .byte 0
SAVED_D022: .byte 0
SAVED_D023: .byte 0

.include "ComputePlayerSymbols.inc"

;------------------------------------------------------------
; Common libs
;------------------------------------------------------------
.include "../../Loader/CartLibStream.s"
.include "../../Loader/SafeStreamImpl.s"
.include "../../Loader/DebugStrings.s"
