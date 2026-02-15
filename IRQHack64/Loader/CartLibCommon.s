.include "Common/System.inc"
.include "Common/IRQHack.inc"

CARTRIDGENMIHANDLERX1 	= $80af
CARTRIDGENMIHANDLERX4	= $80a0
CARTRIDGENMIHANDLERX8 	= $808c

; ============================================================
; CARTRIDGE ROM VERSION CONFIGURATION
; ============================================================
; CURRENT ACTIVE: Old ROM ($80AB) - Istanbul original implementation
;
; To switch to new ROM:
;   1. Uncomment the $80FF line below
;   2. Comment out the $80AB line
;   3. Rebuild entire project (core + plugins)
;
;CARTRIDGE_BANK_VALUE	= $80FF			; New ROMs (if available)
CARTRIDGE_BANK_VALUE	= $80AB			; Old ROMs (ACTIVE - default)
