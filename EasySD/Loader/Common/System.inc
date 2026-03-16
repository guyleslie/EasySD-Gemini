; This file is included by other files.
; It contains system-wide constants.

; KERNAL functions
CHROUT    	= $FFD2
GETIN 	  	= $FFE4
SCNKEY 		= $FF9F
RESETROUTINE = $FCE2

; KERNAL Entry Points (Direct)
K_OPEN   = $F34A
K_CLOSE  = $F291
K_CHKIN  = $F20E
K_CHRIN  = $F157
K_CLRCHN = $F32F

; KERNAL/System vectors
IRQVECTOR	= $0314
ROM_IRQ_HANDLER = $0314 ; Alias for compatibility
SOFTNMIVECTOR	= $0318
NMI_LO		= $0318
NMI_HI		= $0319
IRQ6502		= $FFFE
NMI6502		= $FFFA
DEFAULT_NMI_HANDLER = $FE47 ; a.k.a. ROMNMIHANDLER
ROMNMIHANDLER	= $FE47
ROMIRQHANDLER	= $FF48

; KERNAL RAM Vectors
V_OPEN   = $031A
V_CLOSE  = $031C
V_CHKIN  = $031E
V_CLRCHN = $0322
V_CHRIN  = $0324

; VIC-II registers
BORDER		= $D020
SCREEN		= $D021
VIC_CONTROL_1	= $D011
VIC_RASTER_LINE = $D012
VIC_INT_CONTROL	= $D01A
VIC_INT_ACK	= $D019
VIC_BORDER_COLOR= $D020

; VIC-II Bit masks
VIC_DEN         = $10 ; Display Enable
VIC_INT_RASTER  = $01 ; Raster interrupt bit

; CIA registers
CIA_1_BASE 	= $DC00
CIA_2_BASE 	= $DD00
DATA_A		= 0
DATA_B		= 1
DDR_A		= 2
DDR_B		= 3
TIMER_A_LO	= $04
TIMER_A_HI	= $05
CIA_INT_MASK	= $0D
CIA_TIMER_A_CTRL= $0E
CIA_TIMER_B_CTRL= $0F
CRA_TOD_IN_50HZ			= 128
CRA_SP_MODE_OUTPUT		= 64
CRA_IN_MODE_CNT 		= 32
CRA_FORCE_LOAD 			= 16
CRA_RUN_MODE_ONE_SHOT 	= 8
CRA_OUT_MODE_TOGGLE 	= 4
CRA_PB6_ON 				= 2
CRA_START 				= 1

; I/O ports
PROCESSOR_PORT	= $01
PP_CONFIG_ALL_RAM = $34
PP_CONFIG_RAM_ON_ROM = $35
PP_CONFIG_RAM_ON_BASIC = $36
PP_CONFIG_DEFAULT = $37

; Kernal LOAD vector
V_LOAD   = $0330

; ResidentLoader area — used during multi-load game execution (overlaps FILE_PATH_BUF)
; Safe: during game execution no plugin loading happens; during menu no resident loader
;
; V2 Memory Layout (updated from V1):
;   $033C-$035B  RL_STUB code (~32 bytes): saves X/Y/A/$01, calls RL_HANDLER, restores
;   $035C-$0367  padding (reserved, zero-filled)
;   $0368-$036A  RL_NMI_REDIRECT: JMP ($0318) — written to $FFFA/$FFFB for $01=$35 NMI dispatch
;   $036B-$036C  RL_ORIG_VEC (2 bytes): backup of $0330/$0331
;   $036D        RL_SAVED_01 (1 byte): game's $01 saved during hook
;   $036E        RL_SAVED_X  (1 byte): game's X register at LOAD call time (SA=0 support)
;   $036F        RL_SAVED_Y  (1 byte): game's Y register at LOAD call time (SA=0 support)
;
; Why $FFFA/$FFFB must be updated:
;   Writes to $FFFA/$FFFB always reach RAM (6502: writes always go to RAM).
;   With $01=$35 (HIRAM=0): $E000-$FFFF is RAM → reads from $FFFA/$FFFB see RAM.
;   On NMI the CPU reads $FFFA/$FFFB → gets RL_NMI_REDIRECT → JMP ($0318) → TransferHandler.
;   ROML ($8000-$9FFF) remains accessible with $01=$35 because LORAM=1 → TransferHandler OK.
;   With $01=$37 (HIRAM=1): $FFFA/$FFFB reads from Kernal ROM ($FE43) → also dispatches $0318.
;
RL_STUB         = $033C   ; resident stub entry point (patched into $0330/$0331)
RL_NMI_REDIRECT = $0368   ; JMP ($0318) — installed at $FFFA/$FFFB by RL_INSTALL
RL_ORIG_VEC     = $036B   ; backup of original $0330/$0331 (2 bytes)
RL_SAVED_01     = $036D   ; saved $01 value during LOAD hook (1 byte)
RL_SAVED_X      = $036E   ; saved X register at LOAD call time — SA=0 MEMUSS lo (V2)
RL_SAVED_Y      = $036F   ; saved Y register at LOAD call time — SA=0 MEMUSS hi (V2)

; ResidentLoader handler + mini-CartLib — lives under Kernal ROM ($E000-$FFFF is RAM with $01=$35)
; Writes to this area always go to RAM regardless of $01 setting (6502 write behavior).
; Reads require $01=$35 (HIRAM=0) — RL_STUB ensures this before calling RL_HANDLER.
; NOTE: RL_HANDLER label is defined in ResidentLoader.s (.logical $E800) — not here.
RL_DIR_PATH     = $E840   ; game directory path, 64 bytes (chdir safety — stored on install)
RL_FNAME_BUF    = $E880   ; assembled filename buffer, 36 bytes
RL_FILEINFO_BUF = $E8A4   ; FAT directory entry buffer, 32 bytes
RL_HDR_BUF      = $E8C4   ; 256-byte buffer for reading first file page (PRG header + data)
; RL_MINI_CARTLIB: embedded mini-CartLib, follows rl_main code in handler image.
; Address is not fixed (depends on rl_main size) — defined as RL_WasteCertainTime label.
; Kept here as documentation only; code references RL_* labels, not this address.

; Other common memory locations
FILE_PATH_BUF = $033C
SIDLOAD		= $E000