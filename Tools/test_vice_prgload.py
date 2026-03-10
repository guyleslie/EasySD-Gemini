#!/usr/bin/env python3
"""
EasySD - VICE Automated PRG Load + P2TK Setup Test

Tests KernalBridge PRG loading pipeline and P2TK setup logic via VICE binary
monitor protocol.  No Arduino hardware required.

Test binary: build/vice-tests/prgtest.prg  (assembled from PrgLoadViceTest.s)

Test cases:
  PIPELINE      — Normal load: parse header, copy payload, jump, RTS return
  P2TK_TRIG     — Trigger condition for 4 ENDADDRESS boundary cases
  PAGES_CALC    — Phase2_pages calculation for ENDADDR=$FFFF  (expected $40)
  PHASE3_SETUP  — Phase3 copy loops + NMI vector ($036A) + $0341 override
  NMI_NORMAL    — Normal P2TK NMI vector ($80AF)
  BINARY_CHECK  — Static check: prgplugin.prg contains correct P3 data tables

Usage:
    python Tools/test_vice_prgload.py
    python Tools/test_vice_prgload.py --build
    python Tools/test_vice_prgload.py --verbose
    python Tools/test_vice_prgload.py --keep-vice
    python Tools/test_vice_prgload.py --vice-path "C:/VICE/bin/x64sc.exe"
    python Tools/test_vice_prgload.py --port 6503
"""

import argparse
import os
import sys
import time
from pathlib import Path

# Reuse ViceBinaryMonitor and ViceProcess from the menu test suite
sys.path.insert(0, str(Path(__file__).parent))
from test_vice_menu import ViceBinaryMonitor, ViceProcess

# ── ANSI colours ────────────────────────────────────────────────────────────
GREEN  = '\033[92m'
RED    = '\033[91m'
YELLOW = '\033[93m'
BLUE   = '\033[94m'
CYAN   = '\033[96m'
BOLD   = '\033[1m'
RESET  = '\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
DEFAULT_VICE_PATH = r"E:\Apps\GTK3VICE-3.9-win64\bin\x64sc.exe"
DEFAULT_PORT      = 6503          # different from menu test (6502) to allow parallel runs

# ── Sentinel addresses written by PrgLoadViceTest.s ──────────────────────────
SEN_PARSE       = 0xCF60    # $01 = PARSE done
SEN_COPY        = 0xCF61    # $01 = COPY done
SEN_EXEC        = 0xCF62    # $01 = EXEC done (set by mock payload at $C000)
SEN_RETURN      = 0xCF63    # $01 = RTS returned

SEN_TRIG_C000   = 0xCF70    # trigger: ENDADDR=$C000  (exp $01 = normal)
SEN_TRIG_C002   = 0xCF71    # trigger: ENDADDR=$C002  (exp $01 = normal)
SEN_TRIG_C003   = 0xCF72    # trigger: ENDADDR=$C003  (exp $02 = P2TK)
SEN_TRIG_D000   = 0xCF73    # trigger: ENDADDR=$D000  (exp $02 = P2TK)
SEN_PAGES_FFFF  = 0xCF74    # Phase2_pages for ENDADDR=$FFFF  (exp $40)

SEN_P3_MISMATCH = 0xCF80    # Phase3 table copy mismatch count  (exp $00)
SEN_P3_NMI_LO   = 0xCF81    # $FFFA after Phase3 NMI setup  (exp $6A)
SEN_P3_NMI_HI   = 0xCF82    # $FFFB after Phase3 NMI setup  (exp $03)
SEN_P3_JMP_LO   = 0xCF83    # $0341 after Phase3 NMI setup  (exp $43)
SEN_NRM_NMI_LO  = 0xCF84    # $FFFA after normal NMI setup  (exp $AF)
SEN_NRM_NMI_HI  = 0xCF85    # $FFFB after normal NMI setup  (exp $80)
SEN_NRM_JMP_LO  = 0xCF86    # $0341 after normal NMI setup  (exp $34)
SEN_DONE        = 0xCF8F    # $FF = all tests complete

# ── Expected P3 data table bytes (must match KernalBridge.s exactly) ─────────
#    P3_TAIL_CODE: 39 bytes at $C003 in prgplugin.prg
EXP_P3_TAIL_CODE = bytes([
    0xAD, 0xBB, 0x03, 0x8D, 0xFA, 0xFF,   # LDA $03BB : STA $FFFA
    0xAD, 0xBC, 0x03, 0x8D, 0xFB, 0xFF,   # LDA $03BC : STA $FFFB
    0xAD, 0xBD, 0x03, 0x8D, 0xFC, 0xFF,   # LDA $03BD : STA $FFFC
    0xAD, 0xBE, 0x03, 0x8D, 0xFD, 0xFF,   # LDA $03BE : STA $FFFD
    0xAD, 0xBF, 0x03, 0x8D, 0xFE, 0xFF,   # LDA $03BF : STA $FFFE
    0xAD, 0xC0, 0x03, 0x8D, 0xFF, 0xFF,   # LDA $03C0 : STA $FFFF
    0x4C, 0x34, 0x03,                     # JMP $0334
])  # 39 bytes

#    P3_HANDLER: 52 bytes at $C02A in prgplugin.prg
EXP_P3_HANDLER = bytes([
    0xAD, 0xAB, 0x80,   # +0  LDA $80AB
    0xE0, 0x01,          # +3  CPX #$01
    0xF0, 0x11,          # +5  BEQ +17 -> .phase3
    0x91, 0x6C,          # +7  STA ($6C),Y
    0xC8,                # +9  INY
    0xF0, 0x01,          # +10 BEQ +1  -> .endofblock
    0x40,                # +12 RTI
    0xE6, 0x6D,          # +13 INC $6D
    0xCA,                # +15 DEX
    0xF0, 0x01,          # +16 BEQ +1  -> .endoftransfer
    0x40,                # +18 RTI
    0xA9, 0x64,          # +19 LDA #$64
    0x85, 0x64,          # +21 STA $64
    0x40,                # +23 RTI
    0xC0, 0xFA,          # +24 CPY #$FA
    0xB0, 0x04,          # +26 BCS +4  -> .save_tail
    0x91, 0x6C,          # +28 STA ($6C),Y
    0xC8,                # +30 INY
    0x40,                # +31 RTI
    0x84, 0x77,          # +32 STY $77
    0xAA,                # +34 TAX
    0x98,                # +35 TYA
    0x38,                # +36 SEC
    0xE9, 0xFA,          # +37 SBC #$FA
    0xA8,                # +39 TAY
    0x8A,                # +40 TXA
    0x99, 0xBB, 0x03,    # +41 STA $03BB,Y
    0xA4, 0x77,          # +44 LDY $77
    0xA2, 0x01,          # +46 LDX #$01
    0xC8,                # +48 INY
    0xF0, 0xDA,          # +49 BEQ -38 -> .endofblock
    0x40,                # +51 RTI
])  # 52 bytes

assert len(EXP_P3_TAIL_CODE) == 39, f"P3_TAIL_CODE length mismatch: {len(EXP_P3_TAIL_CODE)}"
assert len(EXP_P3_HANDLER)   == 52, f"P3_HANDLER length mismatch: {len(EXP_P3_HANDLER)}"


# ── Repo paths ────────────────────────────────────────────────────────────────
REPO_ROOT    = Path(__file__).parent.parent
PRGTEST_PRG  = REPO_ROOT / "EasySD" / "build" / "vice-tests" / "prgtest.prg"
PRGPLUGIN_PRG = REPO_ROOT / "EasySD" / "build" / "plugins" / "prgplugin.prg"


# ============================================================================
class VicePrgLoadTester:
    """Runs PrgLoadViceTest.s via VICE binary monitor and verifies sentinels."""

    def __init__(self, vice_path: str, port: int, verbose: bool, keep_vice: bool):
        self.vice_path = vice_path
        self.port      = port
        self.verbose   = verbose
        self.keep_vice = keep_vice
        self.mon: ViceBinaryMonitor | None = None
        self.proc: ViceProcess | None      = None
        self.passes = 0
        self.fails  = 0

    # ── lifecycle ─────────────────────────────────────────────────────────────
    def start(self) -> bool:
        if not Path(self.vice_path).exists():
            print(f"{RED}[ERR] VICE not found: {self.vice_path}{RESET}")
            return False
        if not PRGTEST_PRG.exists():
            print(f"{RED}[ERR] prgtest.prg not found: {PRGTEST_PRG}{RESET}")
            print("      Run: python Tools/build.py debug-vice")
            return False

        print(f"[INIT] Launching VICE with prgtest.prg...")
        self.proc = ViceProcess(str(PRGTEST_PRG), self.vice_path, self.port)
        self.proc.start()

        print(f"[INIT] Connecting to binary monitor on port {self.port}...")
        self.mon = ViceBinaryMonitor("127.0.0.1", self.port)
        for attempt in range(20):
            try:
                self.mon.connect()
                break
            except ConnectionRefusedError:
                time.sleep(0.5)
        else:
            print(f"{RED}[ERR] Could not connect to VICE monitor{RESET}")
            return False

        print(f"{GREEN}[OK] VICE running, monitor connected{RESET}")
        return True

    def stop(self):
        if self.mon:
            try:
                if not self.keep_vice:
                    self.mon.quit()
                else:
                    self.mon.disconnect()
            except Exception:
                pass
        if self.proc and not self.keep_vice:
            self.proc.stop()

    # ── helpers ───────────────────────────────────────────────────────────────
    def _read(self, addr: int, count: int = 1) -> bytes:
        data = self.mon.memory_get(addr, count)
        self.mon.exit_monitor()
        if self.verbose:
            hex_str = " ".join(f"{b:02X}" for b in data)
            print(f"  [MEM] ${addr:04X}: {hex_str}")
        return data

    def _read1(self, addr: int) -> int:
        return self._read(addr, 1)[0]

    def _poll_done(self, timeout: float = 15.0, interval: float = 0.25) -> bool:
        """Wait until SEN_DONE == $FF (all tests complete in prgtest.prg)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            val = self._read1(SEN_DONE)
            if val == 0xFF:
                return True
            time.sleep(interval)
        return False

    def _pass(self, name: str, detail: str = ""):
        label = f"{GREEN}PASS{RESET}"
        print(f"  {label}  {name}" + (f"  ({detail})" if detail else ""))
        self.passes += 1

    def _fail(self, name: str, detail: str = ""):
        label = f"{RED}FAIL{RESET}"
        print(f"  {label}  {name}" + (f"  ({detail})" if detail else ""))
        self.fails += 1

    def _check(self, name: str, addr: int, expected: int):
        got = self._read1(addr)
        if got == expected:
            self._pass(name, f"${addr:04X}=${got:02X}")
        else:
            self._fail(name, f"${addr:04X}=${got:02X} (expected ${expected:02X})")

    # ── test cases ────────────────────────────────────────────────────────────
    def test_pipeline(self) -> bool:
        """Phase 1-3: normal load pipeline sentinel chain."""
        ok = True
        for addr, name, exp in [
            (SEN_PARSE,  "PARSE",  0x01),
            (SEN_COPY,   "COPY",   0x01),
            (SEN_EXEC,   "EXEC",   0x01),
            (SEN_RETURN, "RETURN", 0x01),
        ]:
            got = self._read1(addr)
            if got == exp:
                self._pass(f"PIPELINE/{name}", f"${addr:04X}=${got:02X}")
            else:
                self._fail(f"PIPELINE/{name}", f"${addr:04X}=${got:02X} (exp ${exp:02X})")
                ok = False
        return ok

    def test_p2tk_trig(self) -> bool:
        """Phase 4: P2TK trigger decision — 4 ENDADDRESS boundary cases."""
        cases = [
            (SEN_TRIG_C000, "ENDADDR=$C000", 0x01),  # normal
            (SEN_TRIG_C002, "ENDADDR=$C002", 0x01),  # normal (boundary)
            (SEN_TRIG_C003, "ENDADDR=$C003", 0x02),  # P2TK  (boundary)
            (SEN_TRIG_D000, "ENDADDR=$D000", 0x02),  # P2TK
        ]
        ok = True
        for addr, name, exp in cases:
            got = self._read1(addr)
            tag = "normal" if exp == 0x01 else "P2TK"
            if got == exp:
                self._pass(f"P2TK_TRIG/{name}", f"-> {tag}")
            else:
                got_tag = "normal" if got == 0x01 else "P2TK" if got == 0x02 else f"${got:02X}"
                self._fail(f"P2TK_TRIG/{name}", f"got {got_tag}, expected {tag}")
                ok = False
        return ok

    def test_pages_calc(self) -> bool:
        """Phase 5: Phase2_pages for ENDADDR=$FFFF must be $40 (Phase 3 trigger)."""
        got = self._read1(SEN_PAGES_FFFF)
        if got == 0x40:
            self._pass("PAGES_CALC/FFFF->$40", "Phase 3 trigger correct")
            return True
        else:
            self._fail("PAGES_CALC/FFFF->$40", f"got ${got:02X}, expected $40")
            return False

    def test_phase3_setup(self) -> bool:
        """Phase 6: Phase3 copy + NMI vector ($036A) + $0341 override."""
        ok = True
        # Table copy mismatch count
        got_mm = self._read1(SEN_P3_MISMATCH)
        if got_mm == 0:
            self._pass("PHASE3_SETUP/table_copy", "0 mismatches")
        else:
            self._fail("PHASE3_SETUP/table_copy", f"{got_mm} mismatch(es)")
            ok = False

        # NMI vector and $0341
        for addr, name, exp in [
            (SEN_P3_NMI_LO, "$FFFA (P3 NMI lo)", 0x6A),
            (SEN_P3_NMI_HI, "$FFFB (P3 NMI hi)", 0x03),
            (SEN_P3_JMP_LO, "$0341 (P3 JMP lo)", 0x43),
        ]:
            got = self._read1(addr)
            if got == exp:
                self._pass(f"PHASE3_SETUP/{name}", f"=${got:02X}")
            else:
                self._fail(f"PHASE3_SETUP/{name}", f"=${got:02X} (exp ${exp:02X})")
                ok = False
        return ok

    def test_nmi_normal(self) -> bool:
        """Phase 7: Normal P2TK NMI vector -> $80AF, $0341=$34."""
        ok = True
        for addr, name, exp in [
            (SEN_NRM_NMI_LO, "$FFFA (normal NMI lo)", 0xAF),
            (SEN_NRM_NMI_HI, "$FFFB (normal NMI hi)", 0x80),
            (SEN_NRM_JMP_LO, "$0341 (normal JMP lo)", 0x34),
        ]:
            got = self._read1(addr)
            if got == exp:
                self._pass(f"NMI_NORMAL/{name}", f"=${got:02X}")
            else:
                self._fail(f"NMI_NORMAL/{name}", f"=${got:02X} (exp ${exp:02X})")
                ok = False
        return ok

    def test_binary_check(self) -> bool:
        """Static binary check: prgplugin.prg contains correct P3 data tables.

        prgplugin.prg structure (built by build.py):
          [2-byte PRG header $0801] [BASIC stub ~13 bytes] [KernalBridge raw binary]
        The KernalBridge raw binary starts at $C000 within the EasySD address space
        but is embedded in the PRG starting after the BASIC stub.

        Strategy: locate P3_TAIL_CODE by signature search (AD BB 03 8D FA FF).
        P3_HANDLER follows immediately: $C02A = $C003 + 39, so offset = tail_pos + 39.
        This is robust to changes in the BASIC stub size.
        """
        if not PRGPLUGIN_PRG.exists():
            self._fail("BINARY_CHECK", f"prgplugin.prg not found: {PRGPLUGIN_PRG}")
            return False

        data = PRGPLUGIN_PRG.read_bytes()
        if len(data) < 60:
            self._fail("BINARY_CHECK", f"prgplugin.prg too small ({len(data)} bytes)")
            return False

        # Locate P3_TAIL_CODE by signature (first 6 bytes are unique: AD BB 03 8D FA FF)
        sig = bytes(EXP_P3_TAIL_CODE[:6])
        tail_pos = data.find(sig)
        if tail_pos == -1:
            self._fail("BINARY_CHECK/P3_TAIL_CODE",
                       "signature AD BB 03 8D FA FF not found in prgplugin.prg")
            return False

        # P3_HANDLER is at $C02A = $C003 + ($C02A - $C003) = $C003 + 39 bytes after tail
        handler_pos = tail_pos + len(EXP_P3_TAIL_CODE)  # = tail_pos + 39

        if len(data) < handler_pos + len(EXP_P3_HANDLER):
            self._fail("BINARY_CHECK", f"prgplugin.prg too short for P3_HANDLER")
            return False

        ok = True
        got_tail    = data[tail_pos    : tail_pos    + len(EXP_P3_TAIL_CODE)]
        got_handler = data[handler_pos : handler_pos + len(EXP_P3_HANDLER)]

        if self.verbose:
            print(f"  [BIN] P3_TAIL_CODE found at file offset {tail_pos} "
                  f"(= $C003 in KernalBridge address space)")
            print(f"  [BIN] P3_HANDLER at offset {handler_pos} (= $C02A)")

        if got_tail == EXP_P3_TAIL_CODE:
            self._pass("BINARY_CHECK/P3_TAIL_CODE@$C003",
                       f"{len(EXP_P3_TAIL_CODE)} bytes match (file offset {tail_pos})")
        else:
            diffs = [(i, got_tail[i], EXP_P3_TAIL_CODE[i])
                     for i in range(len(EXP_P3_TAIL_CODE))
                     if i < len(got_tail) and got_tail[i] != EXP_P3_TAIL_CODE[i]]
            self._fail("BINARY_CHECK/P3_TAIL_CODE@$C003",
                       f"{len(diffs)} byte(s) differ; first: "
                       f"offset +{diffs[0][0]} got ${diffs[0][1]:02X} exp ${diffs[0][2]:02X}")
            ok = False

        if got_handler == EXP_P3_HANDLER:
            self._pass("BINARY_CHECK/P3_HANDLER@$C02A",
                       f"{len(EXP_P3_HANDLER)} bytes match (file offset {handler_pos})")
        else:
            diffs = [(i, got_handler[i], EXP_P3_HANDLER[i])
                     for i in range(len(EXP_P3_HANDLER))
                     if i < len(got_handler) and got_handler[i] != EXP_P3_HANDLER[i]]
            self._fail("BINARY_CHECK/P3_HANDLER@$C02A",
                       f"{len(diffs)} byte(s) differ; first: "
                       f"offset +{diffs[0][0]} got ${diffs[0][1]:02X} exp ${diffs[0][2]:02X}")
            ok = False

        return ok

    # ── orchestration ─────────────────────────────────────────────────────────
    def run(self) -> int:
        """Run all tests. Returns 0 on all-pass, 1 on any failure."""
        # ── Binary check (no VICE needed) ─────────────────────────────────────
        print()
        print("=" * 60)
        print(f" {BOLD}EasySD PRG Load + P2TK VICE Test Suite{RESET}")
        print("=" * 60)

        print(f"\n[1/6] {BOLD}BINARY_CHECK{RESET}")
        self.test_binary_check()

        # ── VICE-based tests ──────────────────────────────────────────────────
        if not self.start():
            return 1

        try:
            print("\n[WAIT] Waiting for prgtest.prg to complete (max 15s)...")
            self.mon.exit_monitor()
            if not self._poll_done(timeout=15.0):
                print(f"{RED}[ERR] Timeout: SEN_DONE never set to $FF{RESET}")
                return 1
            print(f"{GREEN}[OK] prgtest.prg completed{RESET}")

            suites = [
                (2, "PIPELINE",     self.test_pipeline),
                (3, "P2TK_TRIG",   self.test_p2tk_trig),
                (4, "PAGES_CALC",  self.test_pages_calc),
                (5, "PHASE3_SETUP",self.test_phase3_setup),
                (6, "NMI_NORMAL",  self.test_nmi_normal),
            ]
            for n, name, fn in suites:
                print(f"\n[{n}/6] {BOLD}{name}{RESET}")
                fn()

        finally:
            self.stop()

        # ── Summary ───────────────────────────────────────────────────────────
        total = self.passes + self.fails
        print()
        print("=" * 60)
        if self.fails == 0:
            print(f" {GREEN}{BOLD}ALL {total} CHECKS PASSED{RESET}")
        else:
            print(f" {RED}{BOLD}{self.fails} FAILED / {self.passes} PASSED  ({total} total){RESET}")
        print("=" * 60)
        return 0 if self.fails == 0 else 1


# ============================================================================
def build(repo_root: Path) -> int:
    import subprocess
    print("[BUILD] Running: python Tools/build.py debug-vice")
    r = subprocess.run(
        [sys.executable, str(repo_root / "Tools" / "build.py"), "debug-vice"],
        cwd=str(repo_root),
    )
    return r.returncode


def main() -> int:
    ap = argparse.ArgumentParser(description="EasySD PRG Load + P2TK VICE test suite")
    ap.add_argument("--build",      "-b", action="store_true",
                    help="Run debug-vice build before testing")
    ap.add_argument("--verbose",    "-v", action="store_true",
                    help="Show memory reads")
    ap.add_argument("--keep-vice",  "-k", action="store_true",
                    help="Leave VICE open after tests")
    ap.add_argument("--vice-path",        default=DEFAULT_VICE_PATH,
                    help=f"Path to x64sc.exe (default: {DEFAULT_VICE_PATH})")
    ap.add_argument("--port",       "-p", type=int, default=DEFAULT_PORT,
                    help=f"Binary monitor TCP port (default: {DEFAULT_PORT})")
    args = ap.parse_args()

    repo_root = Path(__file__).parent.parent

    if args.build:
        if build(repo_root) != 0:
            print(f"{RED}[ERR] Build failed{RESET}")
            return 1

    tester = VicePrgLoadTester(
        vice_path=args.vice_path,
        port=args.port,
        verbose=args.verbose,
        keep_vice=args.keep_vice,
    )
    return tester.run()


if __name__ == "__main__":
    sys.exit(main())
