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