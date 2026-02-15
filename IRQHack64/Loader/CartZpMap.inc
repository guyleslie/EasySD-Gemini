; ============================================================
; EasySD / CartLib - Zero Page map (single source of truth)
; ============================================================

; ---- LoadFileBySize (CartLibHi) uses $80-$87 ----
ZP_LF_SIZE0        = $80
ZP_LF_SIZE1        = $81
ZP_LF_SIZE2        = $82
ZP_LF_SIZE3        = $83
ZP_LF_SKIP_LO      = $84
ZP_LF_SKIP_HI      = $85
ZP_LF_PAYLOAD_LO   = $86
ZP_LF_PAYLOAD_HI   = $87

; ---- SafeStream temps (moved away from $87 collision) ----
ZP_SS_OFFSET       = $8B
ZP_SS_INTERVAL     = $8C
ZP_SS_CHUNK        = $8D
ZP_SS_DELAY        = $8E

; ---- StreamLargeFile (CartLibStream) uses $90-$95 ----
ZP_STREAM_TARGET_ADDR_LO = $90
ZP_STREAM_TARGET_ADDR_HI = $91
ZP_STREAM_BYTES_REMAIN_0 = $92
ZP_STREAM_BYTES_REMAIN_1 = $93
ZP_STREAM_BYTES_REMAIN_2 = $94
ZP_STREAM_BYTES_REMAIN_3 = $95

; ---- CartLibCommon (from $64-$77) ----
ZP_IRQ_WaitHandle       = $64
ZP_IRQ_DATA_LOW         = $6C
ZP_IRQ_DATA_HIGH        = $6D
ZP_IRQ_DATA_LENGTH      = $6B
ZP_IRQ_SEEK_LOW         = $69
ZP_IRQ_SEEK_HIGH        = $6A

; Renamed and moved to avoid conflict with ZP_LF_SIZE0/1/2 ($80-$82)
ZP_IRQ_CALLBACK_LO      = $73
ZP_IRQ_CALLBACK_HI      = $74
ZP_IRQ_SEEK_UPPER_LO    = $75
ZP_IRQ_SEEK_UPPER_HI    = $76
ZP_IRQ_TEMP             = $77