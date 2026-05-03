; ============================================================
; EasySD / CartLib - Zero Page map (single source of truth)
; ============================================================

; ---- LoadFileBySize (CartLibHi) uses $80-$87 ----
ZP_LOADFILE_API_SIZE0        = $80
ZP_LOADFILE_API_SIZE1        = $81
ZP_LOADFILE_API_SIZE2        = $82
ZP_LOADFILE_API_SIZE3        = $83
ZP_LOADFILE_API_SKIP_LO      = $84
ZP_LOADFILE_API_SKIP_HI      = $85
ZP_LOADFILE_API_PAYLOAD_LO   = $86
ZP_LOADFILE_API_PAYLOAD_HI   = $87

; $8B-$8E  FREE (SafeStream removed — params were ignored by Arduino)
;           Handler scratch use: $8B/$8C = copy ptr lo/hi, $8D/$8E = end addr temps

; ---- StreamLargeFile (CartLibStream) uses $90-$95 ----
ZP_STREAM_API_TARGET_LO = $90
ZP_STREAM_API_TARGET_HI = $91
ZP_STREAM_API_REMAIN0 = $92
ZP_STREAM_API_REMAIN1 = $93
ZP_STREAM_API_REMAIN2 = $94
ZP_STREAM_API_REMAIN3 = $95

; ---- CartLibCommon (from $64-$77) ----
ZP_IRQ_STATE_WAITHANDLE       = $64
ZP_IRQ_API_DATA_LO         = $6C
ZP_IRQ_API_DATA_HI        = $6D
ZP_IRQ_API_DATA_LENGTH      = $6B
ZP_IRQ_API_SEEK_LO         = $69
ZP_IRQ_API_SEEK_HI        = $6A

; Renamed and moved to avoid conflict with ZP_LOADFILE_API_SIZE0/1/2 ($80-$82)
ZP_IRQ_API_CALLBACK_LO      = $73
ZP_IRQ_API_CALLBACK_HI      = $74
ZP_IRQ_API_SEEK_UPPER_LO    = $75
ZP_IRQ_API_SEEK_UPPER_HI    = $76
ZP_IRQ_TMP_SCRATCH             = $77

; $033C-$03xx  ResidentLoader area (game execution phase)
; During menu/plugin operation: $033C = FILE_PATH_BUF (filename for CartLib)
; During multi-load game execution (V2 layout):
;   $033C-$036F  RL_STUB code + padding
;   $0370-$0372  RL_NMI_REDIRECT (JMP ($0318), written to $FFFA/$FFFB)
;   $0373-$0374  RL_ORIG_VEC
;   $0375        RL_SAVED_01
;   $0376        RL_SAVED_X   (V2: SA=0 support)
;   $0377        RL_SAVED_Y   (V2: SA=0 support)
;   $0378+       RL receive timeout + first-part launch stubs
; The two uses NEVER overlap — safe dual-purpose.
; See System.inc for all RL_* constants.
