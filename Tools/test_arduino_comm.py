#!/usr/bin/env python3
"""
EasySD - Arduino Communication Test Suite

Tests Arduino firmware via serial debug interface.
No C64 required - communicates directly over USB serial (57600 baud).

The Arduino 'T' command runs a built-in self-test suite that covers:
  SD init, root listing, file open/read/close, non-existent file,
  directory navigation, seek, write/delete, memory stability loop.

Serial debug log format (EasySDLog.h, Sprint 12+):
  [LEVEL][CATEGORY] message
  Levels:   ERR  WARN INFO DBG  TRC
  Categories: SYS SD DIR FILE PROTO PRG ERR
  Examples:
    [INFO][SD]   SD OK                            — SD initialized
    [DBG ][FILE] HandleOpenFile                   — File operation entry
    [DBG ][DIR]  HandleChangeDirectory            — Directory operation
    [ERR ][SD]   SD recover FAIL                  — Critical SD error
    [INFO][SD]   Recovered                        — SD card recovery
  Self-test output (unchanged, always printed):
  [T]    START/END/test names                     — Self-test suite output

Usage:
    python Tools/test_arduino_comm.py COM4                  # Auto test (T command)
    python Tools/test_arduino_comm.py COM4 --interactive    # Interactive mode
    python Tools/test_arduino_comm.py COM4 --test dir_nav   # Dir navigation test
    python Tools/test_arduino_comm.py COM4 --verbose        # Verbose output
"""

import sys
import time
import argparse

try:
    import serial
except ImportError:
    print("ERROR: pyserial not installed. Run: pip install pyserial")
    sys.exit(1)

# ANSI colors
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
CYAN = '\033[96m'
BOLD = '\033[1m'
RESET = '\033[0m'


class ArduinoCommTester:
    def __init__(self, port, baudrate=57600, timeout=5, verbose=False):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.verbose = verbose
        self.ser = None

    def connect(self):
        """Connect to Arduino and read startup banner."""
        print(f"{BLUE}[INIT]{RESET} Connecting to {self.port} at {self.baudrate} baud...")
        try:
            self.ser = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
            time.sleep(2.5)  # Wait for Arduino boot/reset
            print(f"{GREEN}[OK]{RESET} Connected\n")

            # Read startup banner
            banner = self._read_all_available()
            if banner:
                print(f"{CYAN}--- Arduino Boot ---{RESET}")
                for line in banner:
                    print(f"  {line}")
                print(f"{CYAN}--------------------{RESET}\n")
            return True
        except Exception as e:
            print(f"{RED}[FAIL]{RESET} Connection failed: {e}")
            return False

    def disconnect(self):
        if self.ser and self.ser.is_open:
            self.ser.close()

    def _read_all_available(self, wait_ms=500):
        """Read all available lines with a settling delay."""
        time.sleep(wait_ms / 1000.0)
        lines = []
        while self.ser.in_waiting:
            raw = self.ser.readline()
            line = raw.decode('utf-8', errors='ignore').strip()
            if line:
                lines.append(line)
        return lines

    def send_command(self, cmd, arg=None, wait_ms=1000):
        """Send a single-char command with optional argument line.
        Returns list of response lines."""
        self.ser.reset_input_buffer()
        self.ser.write(cmd.encode('ascii'))
        if arg is not None:
            time.sleep(0.3)  # Wait for Arduino to print prompt
            self._read_all_available(wait_ms=200)
            self.ser.write((arg + '\n').encode('ascii'))

        time.sleep(wait_ms / 1000.0)
        lines = []
        deadline = time.time() + 3.0
        while time.time() < deadline:
            while self.ser.in_waiting:
                raw = self.ser.readline()
                line = raw.decode('utf-8', errors='ignore').strip()
                if line:
                    lines.append(line)
                    if self.verbose:
                        print(f"  {CYAN}<<{RESET} {line}")
            if lines:
                time.sleep(0.2)
                while self.ser.in_waiting:
                    raw = self.ser.readline()
                    line = raw.decode('utf-8', errors='ignore').strip()
                    if line:
                        lines.append(line)
                        if self.verbose:
                            print(f"  {CYAN}<<{RESET} {line}")
                break
            time.sleep(0.1)
        return lines

    # ==================================================================
    # Automated test mode - sends 'T' and parses [T] output
    # ==================================================================
    def run_auto_test(self):
        """Send 'T' command and parse results."""
        print(f"{BOLD}{'='*60}{RESET}")
        print(f"{BOLD} EasySD Arduino Self-Test{RESET}")
        print(f"{BOLD}{'='*60}{RESET}\n")

        # Get initial memory
        print(f"{BLUE}[PRE]{RESET} Checking memory...")
        mem_lines = self.send_command('m')
        for line in mem_lines:
            print(f"  {line}")
        print()

        # Send 'T' - run all tests
        print(f"{BLUE}[RUN]{RESET} Sending self-test command (T)...\n")
        self.ser.reset_input_buffer()
        self.ser.write(b'T')

        # Read test output with longer timeout
        test_lines = []
        deadline = time.time() + 30.0
        found_end = False

        while time.time() < deadline and not found_end:
            while self.ser.in_waiting:
                raw = self.ser.readline()
                line = raw.decode('utf-8', errors='ignore').strip()
                if line:
                    test_lines.append(line)
                    if '[T] END:' in line:
                        found_end = True
            time.sleep(0.1)

        # Parse and display results
        passed = 0
        failed = 0

        for line in test_lines:
            if '[T]' in line:
                if 'PASS' in line and 'END' not in line and 'START' not in line:
                    print(f"  {GREEN}PASS{RESET}  {line}")
                    passed += 1
                elif 'FAIL' in line and 'END' not in line and 'START' not in line:
                    print(f"  {RED}FAIL{RESET}  {line}")
                    failed += 1
                elif 'START' in line or 'END' in line:
                    print(f"  {BLUE}----{RESET}  {line}")
                else:
                    print(f"        {line}")
            elif self.verbose:
                print(f"        {line}")

        # Summary
        total = passed + failed
        print(f"\n{BOLD}{'='*60}{RESET}")
        if failed == 0 and passed > 0:
            print(f"{GREEN}{BOLD} ALL {passed} TESTS PASSED{RESET}")
        elif failed > 0:
            print(f"{RED}{BOLD} {failed} TESTS FAILED{RESET} out of {total}")
        else:
            print(f"{YELLOW} No test results found - check connection{RESET}")
        print(f"{BOLD}{'='*60}{RESET}")

        return failed == 0 and passed > 0

    # ==================================================================
    # Directory navigation test (uses existing d/r/l/p commands)
    # ==================================================================
    def test_dir_nav(self):
        """Test directory navigation using existing serial commands."""
        print(f"\n{BOLD}--- Directory Navigation Tests ---{RESET}\n")
        all_ok = True

        # Reset to root
        print(f"{BLUE}[1/4]{RESET} Reset to root...")
        lines = self.send_command('r')
        ok = any('Root:' in l or 'items' in l for l in lines)
        self._report(ok, lines)
        all_ok = all_ok and ok

        # List root
        print(f"{BLUE}[2/4]{RESET} List root...")
        lines = self.send_command('l', wait_ms=2000)
        ok = any('items' in l for l in lines)
        self._report(ok, lines)
        all_ok = all_ok and ok

        # Navigate into TESTDIR
        print(f"{BLUE}[3/4]{RESET} cd TESTDIR...")
        lines = self.send_command('d', 'TESTDIR')
        ok = any('Path:' in l and 'TESTDIR' in l for l in lines)
        self._report(ok, lines)
        all_ok = all_ok and ok

        # Back to root
        print(f"{BLUE}[4/4]{RESET} Reset to root...")
        lines = self.send_command('r')
        ok = any('Root:' in l or 'items' in l for l in lines)
        self._report(ok, lines)
        all_ok = all_ok and ok

        return all_ok

    def _report(self, ok, lines):
        """Print pass/fail for a single step."""
        if ok:
            print(f"  {GREEN}PASS{RESET}")
        else:
            print(f"  {RED}FAIL{RESET}")
            for l in lines:
                print(f"    {l}")

    # ==================================================================
    # Interactive mode
    # ==================================================================
    def run_interactive(self):
        """Interactive serial terminal for manual testing."""
        print(f"{BOLD}EasySD Interactive Mode{RESET}")
        print(f"Commands: h d r l p m T (q to quit)")
        print(f"For 'd' with argument: d DIRNAME\n")

        while True:
            try:
                user = input(f"{YELLOW}>{RESET} ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break

            if not user:
                continue
            if user.lower() == 'q':
                break

            cmd = user[0]
            arg = user[2:].strip() if len(user) > 1 and user[1] == ' ' else None

            if cmd == 'T':
                # T command has longer output
                self.ser.reset_input_buffer()
                self.ser.write(b'T')
                deadline = time.time() + 30.0
                while time.time() < deadline:
                    while self.ser.in_waiting:
                        raw = self.ser.readline()
                        line = raw.decode('utf-8', errors='ignore').strip()
                        if line:
                            print(f"  {line}")
                            if '[T] END:' in line:
                                deadline = 0  # break outer
                    time.sleep(0.1)
            else:
                lines = self.send_command(cmd, arg, wait_ms=2000)
                for line in lines:
                    print(f"  {line}")
            print()


def main():
    parser = argparse.ArgumentParser(description='EasySD Arduino Communication Test Suite')
    parser.add_argument('port', help='Serial port (e.g. COM4, /dev/ttyUSB0)')
    parser.add_argument('--interactive', '-i', action='store_true',
                        help='Interactive mode')
    parser.add_argument('--test', '-t', choices=['dir_nav'],
                        help='Run specific test (dir_nav)')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Verbose output')

    args = parser.parse_args()
    tester = ArduinoCommTester(args.port, verbose=args.verbose)

    if not tester.connect():
        sys.exit(1)

    exit_code = 0
    try:
        if args.interactive:
            tester.run_interactive()
        elif args.test == 'dir_nav':
            if not tester.test_dir_nav():
                exit_code = 1
        else:
            # Default: run Arduino self-test (T command)
            if not tester.run_auto_test():
                exit_code = 1
    except KeyboardInterrupt:
        print(f"\n{YELLOW}[ABORT]{RESET} Interrupted")
    finally:
        tester.disconnect()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
