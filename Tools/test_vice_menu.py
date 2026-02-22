#!/usr/bin/env python3
"""
EasySD - VICE Automated Menu Test Suite

Tests C64 menu behavior via VICE's binary monitor protocol (TCP).
Builds debug-vice, launches x64sc in warp mode, and verifies menu
navigation by reading C64 memory and feeding keystrokes.

Architecture:
  ViceBinaryMonitor  — TCP client for VICE 3.9 binary monitor protocol
  ViceSymbols        — Parses 64tass --vice-labels output (.vs file)
  ViceProcess        — Launches/stops VICE (x64sc.exe)
  ViceMenuTester     — Test orchestrator with 7 test cases

Usage:
    python Tools/test_vice_menu.py                    # Run all tests
    python Tools/test_vice_menu.py --build            # Build first, then test
    python Tools/test_vice_menu.py --verbose          # Verbose output
    python Tools/test_vice_menu.py --keep-vice        # Don't close VICE after
    python Tools/test_vice_menu.py --vice-path <path> # Custom VICE location
    python Tools/test_vice_menu.py --port 6510        # Custom monitor port
"""

import atexit
import os
import re
import socket
import struct
import subprocess
import sys
import time
import argparse
from pathlib import Path

# ANSI colors
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
CYAN = '\033[96m'
BOLD = '\033[1m'
RESET = '\033[0m'

# Default VICE path on this system
DEFAULT_VICE_PATH = r"E:\Apps\GTK3VICE-3.9-win64\bin\x64sc.exe"
DEFAULT_PORT = 6502

# Build paths (relative to repo root)
REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "IRQHack64" / "build"
PRG_PATH = BUILD_DIR / "irqhack64-debug.prg"
LABELS_PATH = BUILD_DIR / "symbol" / "IrqLoaderMenuNew.vs"


# ============================================================================
# ViceSymbols — parse 64tass --vice-labels output
# ============================================================================

class ViceSymbols:
    """Parses VICE-format label file (al [C:]xxxx .LABEL_NAME)."""

    def __init__(self, path: Path):
        self.symbols: dict[str, int] = {}
        self._parse(path)

    def _parse(self, path: Path):
        # Handles "al C:xxxx .NAME", "al xxxx .NAME", and "al xxx .NAME" formats
        pattern = re.compile(r'^al\s+(?:C:)?([0-9a-fA-F]{1,6})\s+\.(\S+)')
        with open(path, 'r') as f:
            for line in f:
                m = pattern.match(line.strip())
                if m:
                    addr = int(m.group(1), 16)
                    name = m.group(2)
                    self.symbols[name] = addr

    def get(self, name: str) -> int | None:
        return self.symbols.get(name)

    def require(self, *names: str) -> dict[str, int]:
        """Return dict of name->addr, raising if any are missing."""
        result = {}
        missing = []
        for name in names:
            addr = self.symbols.get(name)
            if addr is None:
                missing.append(name)
            else:
                result[name] = addr
        if missing:
            raise KeyError(f"Missing required symbols: {', '.join(missing)}")
        return result

    def __len__(self):
        return len(self.symbols)


# ============================================================================
# ViceBinaryMonitor — VICE 3.9 binary monitor TCP protocol
# ============================================================================

class ViceBinaryMonitor:
    """TCP client for VICE binary monitor protocol.

    Wire format (VICE 3.9, API version 0x02):
      Request:  STX(0x02) + api_ver(0x02) + body_len:u32le + req_id:u32le + cmd:u8 + body
      Response: STX(0x02) + api_ver(0x02) + body_len:u32le + resp_type:u8 + err:u8 + req_id:u32le + body

    Commands used:
      0x01 = memory_get
      0x72 = keyboard_feed
      0x81 = ping
      0xAA = exit (resume)
      0xBB = quit
    """

    STX = 0x02
    API_VERSION = 0x02
    # Response header: STX(1) + api_ver(1) + body_len(4) + resp_type(1) + err(1) + req_id(4) = 12 bytes
    RESP_HEADER_SIZE = 12
    # Commands
    CMD_MEMORY_GET = 0x01
    CMD_KEYBOARD_FEED = 0x72
    CMD_PING = 0x81
    CMD_EXIT = 0xAA
    CMD_QUIT = 0xBB

    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT,
                 timeout: float = 5.0, verbose: bool = False):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.verbose = verbose
        self.sock: socket.socket | None = None
        self._req_id = 0

    def connect(self, retries: int = 20, delay: float = 0.5) -> bool:
        """Connect to VICE binary monitor with retries."""
        for attempt in range(retries):
            try:
                self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.sock.settimeout(self.timeout)
                self.sock.connect((self.host, self.port))
                # VICE may send events on connect — drain them
                self._drain_initial()
                if self.verbose:
                    print(f"  {CYAN}[MON]{RESET} Connected to {self.host}:{self.port}")
                return True
            except (ConnectionRefusedError, OSError):
                if self.sock:
                    self.sock.close()
                    self.sock = None
                if attempt < retries - 1:
                    time.sleep(delay)
        return False

    def _drain_initial(self):
        """Read and discard any data VICE sends on initial connect.
        VICE may send a 'stopped' event when loading -moncommands."""
        time.sleep(0.3)
        self.sock.setblocking(False)
        try:
            while True:
                data = self.sock.recv(4096)
                if not data:
                    break
                if self.verbose:
                    print(f"  {CYAN}[MON] drained {len(data)}B{RESET}")
        except BlockingIOError:
            pass
        finally:
            self.sock.setblocking(True)
            self.sock.settimeout(self.timeout)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _next_id(self) -> int:
        self._req_id += 1
        return self._req_id

    def _send_request(self, command: int, body: bytes = b"") -> int:
        """Send a binary monitor request. Returns the request ID."""
        req_id = self._next_id()
        # body_len = length of everything after the header (just the body bytes)
        body_len = len(body)
        # Header: STX + API_VER + body_len:u32le + req_id:u32le + command:u8
        header = struct.pack("<BBIIB", self.STX, self.API_VERSION,
                             body_len, req_id, command)
        packet = header + body
        if self.verbose:
            print(f"  {CYAN}[MON] >> cmd=0x{command:02X} id={req_id} "
                  f"body={len(body)}B{RESET}")
        self.sock.sendall(packet)
        return req_id

    def _recv_response(self, expected_id: int | None = None) -> tuple[int, int, bytes]:
        """Receive a binary monitor response.
        Returns (response_type, error_code, body).
        Skips unsolicited responses (events) until we get our expected_id.
        """
        while True:
            # Read header: STX(1) + api_ver(1) + body_len(4) + resp_type(1) + err(1) + req_id(4) = 12
            header = self._recv_exact(self.RESP_HEADER_SIZE)
            stx = header[0]
            if stx != self.STX:
                raise ConnectionError(f"Bad STX: 0x{stx:02X}")
            # api_ver = header[1]
            body_length = struct.unpack_from("<I", header, 2)[0]
            resp_type = header[6]
            error_code = header[7]
            resp_id = struct.unpack_from("<I", header, 8)[0]

            body = self._recv_exact(body_length) if body_length > 0 else b""

            if self.verbose:
                print(f"  {CYAN}[MON] << type=0x{resp_type:02X} err={error_code} "
                      f"id={resp_id} body={len(body)}B{RESET}")

            # If this is an unsolicited event (id=0xFFFFFFFF or not our id), skip it
            if expected_id is not None and resp_id != expected_id:
                continue
            return resp_type, error_code, body

    def _recv_exact(self, n: int) -> bytes:
        """Receive exactly n bytes."""
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data.extend(chunk)
        return bytes(data)

    def ping(self) -> bool:
        """Send ping, verify response."""
        try:
            req_id = self._send_request(self.CMD_PING)
            _, error_code, _ = self._recv_response(req_id)
            return error_code == 0
        except (OSError, ConnectionError):
            return False

    def memory_get(self, start: int, end: int, memspace: int = 0,
                   bank_id: int = 0, side_effects: bool = False) -> bytes:
        """Read C64 memory. Returns raw bytes.
        Body: side_effects(1) + start(2) + end(2) + memspace(1) + bank_id(2)"""
        se = 1 if side_effects else 0
        body = struct.pack("<BHHBH", se, start, end, memspace, bank_id)
        req_id = self._send_request(self.CMD_MEMORY_GET, body)
        _, error_code, resp_body = self._recv_response(req_id)
        if error_code != 0:
            raise RuntimeError(f"memory_get error: {error_code}")
        # Response body: length:u16le + data
        if len(resp_body) >= 2:
            data_len = struct.unpack_from("<H", resp_body, 0)[0]
            return resp_body[2:2 + data_len]
        return resp_body

    def read_byte(self, addr: int) -> int:
        """Read a single byte from C64 memory."""
        data = self.memory_get(addr, addr)
        return data[0]

    def read_word(self, addr: int) -> int:
        """Read a 16-bit word (little-endian) from C64 memory."""
        data = self.memory_get(addr, addr + 1)
        return data[0] | (data[1] << 8)

    def keyboard_feed(self, text: str) -> bool:
        """Feed text into VICE keyboard buffer."""
        encoded = text.encode('ascii')
        body = struct.pack("<B", len(encoded)) + encoded
        req_id = self._send_request(self.CMD_KEYBOARD_FEED, body)
        _, error_code, _ = self._recv_response(req_id)
        return error_code == 0

    def exit_monitor(self) -> bool:
        """Resume emulation (exit monitor/break state)."""
        try:
            req_id = self._send_request(self.CMD_EXIT)
            _, error_code, _ = self._recv_response(req_id)
            return error_code == 0
        except (OSError, ConnectionError):
            return False

    def quit_vice(self) -> bool:
        """Tell VICE to quit."""
        try:
            self._send_request(self.CMD_QUIT)
            return True
        except (OSError, ConnectionError):
            return False


# ============================================================================
# ViceProcess — launch/stop VICE
# ============================================================================

class ViceProcess:
    """Manages VICE x64sc process lifecycle."""

    def __init__(self, vice_path: str, port: int = DEFAULT_PORT,
                 verbose: bool = False):
        self.vice_path = vice_path
        self.port = port
        self.verbose = verbose
        self.proc: subprocess.Popen | None = None

    def start(self, prg_path: Path, labels_path: Path | None = None) -> bool:
        """Launch VICE with binary monitor enabled."""
        if not Path(self.vice_path).exists():
            print(f"{RED}[ERR]{RESET} VICE not found: {self.vice_path}")
            return False

        cmd = [
            self.vice_path,
            "-binarymonitor",
            "-binarymonitoraddress", f"ip4://127.0.0.1:{self.port}",
            "+sound",
            "-warp",
            "-autostart", str(prg_path),
        ]
        # Note: -moncommands is NOT used because VICE treats label addresses
        # as breakpoints, which stops emulation on every label hit.
        # We parse the .vs file ourselves in ViceSymbols instead.

        if self.verbose:
            print(f"  {CYAN}[VICE]{RESET} {' '.join(cmd)}")

        kwargs = {
            "stdout": subprocess.DEVNULL,
            "stderr": subprocess.DEVNULL,
        }
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP

        self.proc = subprocess.Popen(cmd, **kwargs)
        atexit.register(self._cleanup)

        if self.verbose:
            print(f"  {CYAN}[VICE]{RESET} PID {self.proc.pid}")
        return True

    def is_running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def stop(self):
        """Terminate VICE process."""
        if self.proc:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except (subprocess.TimeoutExpired, OSError):
                try:
                    self.proc.kill()
                except OSError:
                    pass
            self.proc = None

    def _cleanup(self):
        """atexit handler for crash safety."""
        self.stop()


# ============================================================================
# ViceMenuTester — test orchestrator
# ============================================================================

class ViceMenuTester:
    """Runs automated tests against the C64 menu in VICE."""

    def __init__(self, vice_path: str, port: int = DEFAULT_PORT,
                 verbose: bool = False, keep_vice: bool = False):
        self.vice_path = vice_path
        self.port = port
        self.verbose = verbose
        self.keep_vice = keep_vice
        self.mon: ViceBinaryMonitor | None = None
        self.vice: ViceProcess | None = None
        self.sym: ViceSymbols | None = None

    def setup(self) -> bool:
        """Launch VICE, connect monitor, load symbols."""
        # Check PRG exists
        if not PRG_PATH.exists():
            print(f"{RED}[ERR]{RESET} PRG not found: {PRG_PATH}")
            print(f"       Run: python Tools/build.py debug-vice")
            return False

        # Load symbols
        if not LABELS_PATH.exists():
            print(f"{RED}[ERR]{RESET} Labels file not found: {LABELS_PATH}")
            print(f"       Run: python Tools/build.py debug-vice")
            return False

        self.sym = ViceSymbols(LABELS_PATH)
        if self.verbose:
            print(f"  {CYAN}[SYM]{RESET} Loaded {len(self.sym)} symbols from {LABELS_PATH.name}")

        # Verify required symbols exist
        try:
            self.sym.require("CURRENTROW", "CURPAGEITEMS", "DIRLEVEL")
        except KeyError as e:
            print(f"{RED}[ERR]{RESET} {e}")
            return False

        # Launch VICE
        print(f"{BLUE}[INIT]{RESET} Launching VICE...")
        self.vice = ViceProcess(self.vice_path, self.port, self.verbose)
        if not self.vice.start(PRG_PATH):
            return False

        # Connect binary monitor
        print(f"{BLUE}[INIT]{RESET} Connecting to binary monitor on port {self.port}...")
        self.mon = ViceBinaryMonitor("127.0.0.1", self.port,
                                     verbose=self.verbose)
        if not self.mon.connect():
            print(f"{RED}[ERR]{RESET} Could not connect to VICE monitor")
            self.vice.stop()
            return False

        # Ping to verify
        if not self.mon.ping():
            print(f"{RED}[ERR]{RESET} VICE monitor ping failed")
            self.teardown()
            return False

        # Resume emulation — VICE may be in stopped state after loading
        # -moncommands labels, which triggers a "stopped" event.
        self.mon.exit_monitor()
        print(f"{GREEN}[OK]{RESET} VICE running, monitor connected\n")

        # Wait for C64 to boot, autostart, show intro (~3s), then reach menu.
        # Each memory_get may stop the emulation, so we resume after each poll.
        print(f"{BLUE}[INIT]{RESET} Waiting for C64 menu to load...")
        curpage_addr = self.sym.get("CURPAGEITEMS")
        deadline = time.time() + 30.0
        while time.time() < deadline:
            self.mon.exit_monitor()   # ensure emulation is running
            time.sleep(1.0)
            try:
                val = self.mon.read_byte(curpage_addr)
                if val != 0 and val != 0xFF:
                    if self.verbose:
                        print(f"  {CYAN}[INIT]{RESET} CURPAGEITEMS={val}, menu ready")
                    # Resume one more time so the menu finishes rendering
                    self.mon.exit_monitor()
                    time.sleep(0.5)
                    break
            except Exception:
                pass
        else:
            print(f"{RED}[ERR]{RESET} Timeout waiting for menu to load")
            self.teardown()
            return False
        return True

    def teardown(self):
        """Clean up VICE and monitor."""
        if self.mon:
            if self.keep_vice:
                self.mon.close()
            else:
                self.mon.quit_vice()
                time.sleep(0.5)
                self.mon.close()
        if self.vice and not self.keep_vice:
            self.vice.stop()

    def _press_key(self, key: str, settle: float = 0.3):
        """Feed a single key and wait for the menu to process it.
        Resumes emulation so the C64 can read the keystroke via GETIN."""
        self.mon.keyboard_feed(key)
        self.mon.exit_monitor()
        time.sleep(settle)

    def _read_sym_byte(self, name: str) -> int:
        """Read a byte from a symbol's address."""
        addr = self.sym.get(name)
        if addr is None:
            raise KeyError(f"Symbol not found: {name}")
        return self.mon.read_byte(addr)

    # ==================================================================
    # Test cases
    # ==================================================================

    def test_init(self) -> bool:
        """Test 1: Verify initial state after menu loads."""
        # Check sentinel: $DE42 at DEBUG_MAGIC ($CF41)
        sentinel = self.mon.read_word(0xCF41)
        if sentinel != 0x42DE:
            if self.verbose:
                print(f"  Sentinel at $CF41: ${sentinel:04X} (expected $42DE)")
            # Sentinel may not be present in all builds — warn but continue
            if self.verbose:
                print(f"  {YELLOW}[WARN]{RESET} Debug sentinel not found (non-fatal)")

        curpage = self._read_sym_byte("CURPAGEITEMS")
        currow = self._read_sym_byte("CURRENTROW")
        dirlevel = self._read_sym_byte("DIRLEVEL")

        ok = curpage == 5 and currow == 0 and dirlevel == 0
        if self.verbose or not ok:
            print(f"  CURPAGEITEMS={curpage} (exp 5), "
                  f"CURRENTROW={currow} (exp 0), "
                  f"DIRLEVEL={dirlevel} (exp 0)")
        return ok

    def test_nav_down(self) -> bool:
        """Test 2: Press DOWN (-), CURRENTROW should increment."""
        before = self._read_sym_byte("CURRENTROW")
        self._press_key("-")
        after = self._read_sym_byte("CURRENTROW")

        ok = after == before + 1
        if self.verbose or not ok:
            print(f"  CURRENTROW: {before} -> {after} (exp {before + 1})")
        return ok

    def test_nav_up(self) -> bool:
        """Test 3: Press UP (+), CURRENTROW should decrement."""
        before = self._read_sym_byte("CURRENTROW")
        self._press_key("+")
        after = self._read_sym_byte("CURRENTROW")

        ok = after == before - 1
        if self.verbose or not ok:
            print(f"  CURRENTROW: {before} -> {after} (exp {before - 1})")
        return ok

    def test_nav_wrap(self) -> bool:
        """Test 4: Cursor wraps at list boundaries."""
        # Go to top first
        for _ in range(10):
            self._press_key("+", settle=0.1)
        row = self._read_sym_byte("CURRENTROW")
        if row != 0:
            if self.verbose:
                print(f"  Could not reach row 0 (at {row})")
            return False

        # Press UP at top — should wrap to bottom (CURPAGEITEMS - 1)
        self._press_key("+")
        row = self._read_sym_byte("CURRENTROW")
        curpage = self._read_sym_byte("CURPAGEITEMS")
        expected = curpage - 1

        ok = row == expected
        if self.verbose or not ok:
            print(f"  Wrap UP at 0: CURRENTROW={row} (exp {expected})")
        return ok

    def test_enter_dir(self) -> bool:
        """Test 5: Select 'merhaba' dir (row 0), press Enter, DIRLEVEL->1."""
        # Navigate to row 0 (merhaba) — press UP until we get there
        for _ in range(20):
            row = self._read_sym_byte("CURRENTROW")
            if row == 0:
                break
            self._press_key("+")
        row = self._read_sym_byte("CURRENTROW")
        if row != 0:
            if self.verbose:
                print(f"  Could not reach row 0 (at {row})")

        # Press Enter to enter directory
        self._press_key("\r", settle=0.5)

        dirlevel = self._read_sym_byte("DIRLEVEL")
        curpage = self._read_sym_byte("CURPAGEITEMS")

        ok = dirlevel == 1 and curpage == 6
        if self.verbose or not ok:
            print(f"  DIRLEVEL={dirlevel} (exp 1), CURPAGEITEMS={curpage} (exp 6)")
        return ok

    def test_go_back(self) -> bool:
        """Test 6: Select '..' in DIR2 (row 0), press Enter, DIRLEVEL->0."""
        # In DIR2, row 0 should be ".." — press UP until we get there
        for _ in range(20):
            row = self._read_sym_byte("CURRENTROW")
            if row == 0:
                break
            self._press_key("+")
        row = self._read_sym_byte("CURRENTROW")
        if row != 0:
            if self.verbose:
                print(f"  Could not reach row 0 (at {row})")

        # Press Enter on ".."
        self._press_key("\r", settle=0.5)

        dirlevel = self._read_sym_byte("DIRLEVEL")
        curpage = self._read_sym_byte("CURPAGEITEMS")

        ok = dirlevel == 0 and curpage == 5
        if self.verbose or not ok:
            print(f"  DIRLEVEL={dirlevel} (exp 0), CURPAGEITEMS={curpage} (exp 5)")
        return ok

    def test_screen_verify(self) -> bool:
        """Test 7: Read screen RAM at $0454, verify 'merhaba' screen codes."""
        # Row 0 filename is at COLS[1] = $0454 (COLS[0]=$042C is the header row)
        # Screen codes for lowercase ASCII: a=1, b=2, ..., z=26
        # "merhaba" = [13, 5, 18, 8, 1, 2, 1]
        expected = [13, 5, 18, 8, 1, 2, 1]
        data = self.mon.memory_get(0x0454, 0x0454 + len(expected) - 1)
        actual = list(data)

        ok = actual == expected
        if self.verbose or not ok:
            print(f"  Screen @ $0454: {actual} (exp {expected})")
        return ok

    # ==================================================================
    # Run all tests
    # ==================================================================

    def run_all(self) -> bool:
        """Execute all 7 test cases. Returns True if all pass."""
        tests = [
            ("INIT", self.test_init),
            ("NAV_DOWN", self.test_nav_down),
            ("NAV_UP", self.test_nav_up),
            ("NAV_WRAP", self.test_nav_wrap),
            ("ENTER_DIR", self.test_enter_dir),
            ("GO_BACK", self.test_go_back),
            ("SCREEN_VERIFY", self.test_screen_verify),
        ]

        print(f"{BOLD}{'=' * 60}{RESET}")
        print(f"{BOLD} EasySD VICE Menu Test Suite{RESET}")
        print(f"{BOLD}{'=' * 60}{RESET}\n")

        passed = 0
        failed = 0

        for i, (name, test_fn) in enumerate(tests, 1):
            print(f"{BLUE}[{i}/{len(tests)}]{RESET} {name}...", end=" ", flush=True)
            try:
                ok = test_fn()
            except Exception as e:
                ok = False
                print(f"\n  {RED}Exception: {e}{RESET}")

            if ok:
                print(f"{GREEN}PASS{RESET}")
                passed += 1
            else:
                print(f"{RED}FAIL{RESET}")
                failed += 1

        # Summary
        total = passed + failed
        print(f"\n{BOLD}{'=' * 60}{RESET}")
        if failed == 0 and passed > 0:
            print(f"{GREEN}{BOLD} ALL {passed} TESTS PASSED{RESET}")
        elif failed > 0:
            print(f"{RED}{BOLD} {failed} TESTS FAILED{RESET} out of {total}")
        else:
            print(f"{YELLOW} No test results{RESET}")
        print(f"{BOLD}{'=' * 60}{RESET}")

        return failed == 0 and passed > 0


# ============================================================================
# Build helper
# ============================================================================

def run_build():
    """Run debug-vice build."""
    print(f"{BLUE}[BUILD]{RESET} Running: python Tools/build.py debug-vice\n")
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "Tools" / "build.py"), "debug-vice"],
        cwd=str(REPO_ROOT),
    )
    if result.returncode != 0:
        print(f"{RED}[ERR]{RESET} Build failed")
        return False
    print()
    return True


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="EasySD VICE Automated Menu Test Suite")
    parser.add_argument("--build", "-b", action="store_true",
                        help="Build debug-vice before testing")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output (monitor traffic, memory reads)")
    parser.add_argument("--keep-vice", "-k", action="store_true",
                        help="Keep VICE open after tests complete")
    parser.add_argument("--vice-path", default=DEFAULT_VICE_PATH,
                        help=f"Path to x64sc (default: {DEFAULT_VICE_PATH})")
    parser.add_argument("--port", "-p", type=int, default=DEFAULT_PORT,
                        help=f"Binary monitor port (default: {DEFAULT_PORT})")

    args = parser.parse_args()

    # Build if requested
    if args.build:
        if not run_build():
            sys.exit(1)

    # Run tests
    tester = ViceMenuTester(
        vice_path=args.vice_path,
        port=args.port,
        verbose=args.verbose,
        keep_vice=args.keep_vice,
    )

    if not tester.setup():
        sys.exit(1)

    exit_code = 0
    try:
        if not tester.run_all():
            exit_code = 1
    except KeyboardInterrupt:
        print(f"\n{YELLOW}[ABORT]{RESET} Interrupted")
        exit_code = 1
    finally:
        tester.teardown()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
