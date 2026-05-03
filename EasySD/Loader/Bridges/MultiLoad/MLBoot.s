;================================================================================
; MLBoot.s — Multi-Load Prologue Blob
;================================================================================
;
; PURPOSE:
;   Self-installing prologue PRG that the Arduino synthesises and transmits in
;   place of the user-selected first-part PRG when the selection lives under
;   /MULTILOAD/<game>/. Replaces the legacy EASYLOAD.PRG + MultiLoad.s MAIN
;   pipeline with a single hand-written blob built into FlashLib.h.
;
; FLOW:
;   1. Arduino patches MLBOOT_FIRSTPART_LEN/NAME and MLBOOT_LAUNCH_PATH with
;      the selected first-part PRG and game directory, then sends the blob via
;      the standard LoaderStub path.
;   2. C64 receives, lands at $C000, then jumps past the patched launch fields
;      into MAIN.
;   3. MAIN calls RL_INSTALL — copies RL_STUB to $033C, RL_HANDLER+
;      RL_MINI_CARTLIB to $E800, patches $0330/$0331, writes RL_NMI_REDIRECT
;      to $FFFA/$FFFB.
;   4. MAIN copies MLBOOT_LAUNCH_PATH to RL_DIR_PATH, sets up the Kernal
;      filename pointer to MLBOOT_FIRSTPART_NAME, and issues JSR $FFD5
;      (Kernal LOAD) with device 8, SA=1.
;   5. The LOAD goes through $0330 → RL_STUB → RL_HANDLER → Arduino's existing
;      HandleGotoPath/HandleOpenFile/HandleReadFile path. The resident loader
;      restores /MULTILOAD/<game>/ before every LOAD.
;   6. MAIN jumps to RL_BOOT_LOAD_STUB in low RAM.  That stub performs the
;      Kernal LOAD and then jumps to RL_LAUNCH_AFTER_LOAD under $01=$35, so
;      large first-part PRGs may overwrite $C000 without corrupting control flow.
;   7. In-game LOAD "X",8,1 calls hit the resident hook at $033C and stream
;      from the same SD directory through Arduino.
;
; LAYOUT (offsets locked — Arduino patches via these byte offsets):
;
;   $C000   JMP MAIN                         ; 3 bytes
;   $C003   .byte VERSION                    ; 1 byte sentinel (= 5 for MLBoot)
;   $C004   MLBOOT_FIRSTPART_LEN  .byte 0    ; patched per launch by Arduino
;   $C005   MLBOOT_FIRSTPART_NAME .fill 20,0 ; patched, NUL-padded
;   $C019   MLBOOT_LAUNCH_PATH .fill 64,0 ; patched, NUL-padded
;   $C059   MAIN
;
; Filename field budget: 20 bytes incl. ".PRG" = 16-char PETSCII max.
;================================================================================

; Layout offsets — keep in sync with CartApi.cpp::SendMLBootBlob
MLBOOT_VERSION               = 5
MLBOOT_FIRSTPART_LEN_OFFSET  = $04
MLBOOT_FIRSTPART_NAME_OFFSET = $05
MLBOOT_FIRSTPART_NAME_MAX    = 20
MLBOOT_LAUNCH_PATH_OFFSET    = $19
MLBOOT_LAUNCH_PATH_MAX       = 64

;-----------------------------------------------------------------------
; Includes — MLBoot is a self-contained standalone-buildable blob, so it
; pulls in System/EasySD/CartZpMap directly (the prebuild_checks whitelist
; allows this in addition to CartLibStream.s — see Tools/build.py).
;-----------------------------------------------------------------------
.include "../../Common/System.inc"
.include "../../Common/EasySD.inc"
.include "../../CartZpMap.inc"

; CartLibCommon.s constants needed by RL_NMITAB and RL_WaitProcessing
; (mirrored here so MLBoot does not have to include CartLib.s).
CARTRIDGENMIHANDLERX1 = $80AF
CARTRIDGENMIHANDLERX4 = $80A0
CARTRIDGENMIHANDLERX8 = $808C
CARTRIDGE_BANK_VALUE  = $80AB

	*=$C000
	JMP MAIN

	.byte MLBOOT_VERSION             ; $C003 — version sentinel
MLBOOT_FIRSTPART_LEN:
	.byte 0                          ; $C004 — patched by Arduino
MLBOOT_FIRSTPART_NAME:
	.fill 20, 0                      ; $C005-$C018 — patched by Arduino
MLBOOT_LAUNCH_PATH:
	.fill 64, 0                      ; $C019-$C058 — patched by Arduino

;================================================================================
; MAIN — entry point (after patched launch fields)
; Runs in default $01=$37 (BASIC ROM + Kernal ROM + I/O all visible).
;================================================================================

MAIN:
	;--- 1. Install resident LOAD hook (RL_STUB + RL_HANDLER images, vectors).
	JSR RL_INSTALL

	;--- 1b. Persist launch directory for the resident chdir safety path.
	LDY #0
ml_copy_path:
	LDA MLBOOT_LAUNCH_PATH, Y
	STA RL_DIR_PATH, Y
	INY
	CPY #MLBOOT_LAUNCH_PATH_MAX
	BNE ml_copy_path

	;--- 1c. Settle delay (~250 ms) — race fix.
	; Arduino's LoadAndLaunchFile() attaches cartInterface.StartListening()
	; immediately after SendMLBootBlob returns. This delay leaves margin for
	; the C64 transfer launcher to exit and for the Arduino IO2 ISR to be live
	; before RL_StartTalking emits the first handshake bytes ($64 $46 $17).
	; ~250 k cycles ≈ 250 ms at PAL 0.985 MHz / 244 ms at NTSC 1.022 MHz.
	LDX #200
ml_settle_outer:
	LDY #0
ml_settle_inner:
	DEY
	BNE ml_settle_inner
	DEX
	BNE ml_settle_outer

	;--- 2. Set up Kernal filename pointer.
	LDA MLBOOT_FIRSTPART_LEN
	STA KERNAL_FILENAME_LENGTH       ; $B7
	LDA #<MLBOOT_FIRSTPART_NAME
	STA KERNAL_FILENAME_LOW          ; $BB
	LDA #>MLBOOT_FIRSTPART_NAME
	STA KERNAL_FILENAME_HIGH         ; $BC

	;--- 3. Device 8, secondary address 1 (= use the PRG header's load address).
	LDA #1
	STA KERNAL_SECONDARY_ADDRESS     ; $B9
	LDA #8
	STA KERNAL_DEVICE_NUMBER         ; $BA

	;--- 4. Kernal LOAD + launch.  The JSR $FFD5 lives in low RAM so the
	;   return address cannot point into this $C000 blob after a large PRG
	;   overwrites it.  This never returns on success.
	JMP RL_BOOT_LOAD_STUB

;================================================================================
; ResidentLoader (RL_STUB_IMAGE, RL_HANDLER_IMAGE, RL_INSTALL, RL_UNINSTALL)
; Included verbatim. Image .logical addresses ($033C / $E800) drive label
; resolution; the bytes are physically appended to MLBoot's $C000+ region
; and copied to their runtime addresses by RL_INSTALL.
;================================================================================
.include "../../ResidentLoader.s"

;================================================================================
; Overflow guard — must not reach I/O space at $D000.
;================================================================================
.if * > $D000
	.error "MLBoot blob overflow: exceeds $D000 (I/O space)"
.endif
