#include "EasySD.h"
#include "CartInterface.h"
#include "CartApi.h"
#include "EasySDLog.h"
#include <Arduino.h>
#include <SPI.h>
#include <SdFat.h>
#include <FreeStack.h>

SdFat sd;
DirFunction dirFunc;
CartApi cartApi;
CartInterface cartInterface;

// Boot state machine — cold boot holds C64 in /RESET until AVR is fully ready,
// then releases to BASIC. Menu is only loaded on explicit SEL button press.
enum BootState : uint8_t {
  BOOT_HOLD_RESET,      // C64 held in /RESET, AVR starting
  BOOT_INIT_SD,         // Initializing SPI + SD card
  BOOT_INIT_RUNTIME,    // cartApi.Init() — directory setup
  BOOT_RELEASE_BASIC,   // Release C64 to BASIC (cartridge hidden)
  RUNNING_READY,        // Fully operational, waiting for SEL press
  BOOT_ERROR            // SD init failed, C64 released to BASIC
};

const unsigned char stateNone = 0;
const unsigned char statePressed = 1;

unsigned char state = stateNone;
unsigned long pressTimeMs = 0;
unsigned long buttonEnableAtMs = 0;
bool runtimeReady = false;
static BootState bootState = BOOT_HOLD_RESET;
bool selStableReleased = true;
bool selCandidateReleased = true;
unsigned long selCandidateSinceMs = 0;

const unsigned char chipSelect = 10;
const unsigned long BUTTON_BOOT_GUARD_MS = 500;
const unsigned long BUTTON_POST_ACTION_GUARD_MS = 120;
const unsigned long BUTTON_DEBOUNCE_MS = 12;
const unsigned long BUTTON_LONG_PRESS_MS = 1000;
const unsigned long SEL_STABLE_MS = 8;
const int SEL_PRESSED_THRESHOLD = 256;
const int SEL_RELEASED_THRESHOLD = 768;
static constexpr uint16_t SRAM_WARN_FREE_BYTES = 350;
static constexpr uint16_t SRAM_CRITICAL_FREE_BYTES = 300;

static void suppressButtonsFor(unsigned long delayMs) {
  buttonEnableAtMs = millis() + delayMs;
  state = stateNone;
  pressTimeMs = 0;
}

static bool sampleSelReleasedRaw() {
  return analogRead(SEL) >= SEL_RELEASED_THRESHOLD;
}

static void rearmSelTracking() {
  // Seed the stable/candidate state from the current electrical level so the
  // next press is measured against the real input, not leftover state from a
  // previous reset or menu transfer.
  bool released = sampleSelReleasedRaw();
  selStableReleased = released;
  selCandidateReleased = released;
  selCandidateSinceMs = millis();
}

static bool serviceSelReleased() {
  const int sample = analogRead(SEL);
  bool nextCandidateReleased = selStableReleased
      ? (sample > SEL_PRESSED_THRESHOLD)
      : (sample >= SEL_RELEASED_THRESHOLD);

  unsigned long now = millis();
  if (nextCandidateReleased != selCandidateReleased) {
    selCandidateReleased = nextCandidateReleased;
    selCandidateSinceMs = now;
  } else if (selStableReleased != selCandidateReleased &&
             (unsigned long)(now - selCandidateSinceMs) >= SEL_STABLE_MS) {
    selStableReleased = selCandidateReleased;
  }

  return selStableReleased;
}

#ifdef EASYSD_DEBUG_SERIAL
void ShowMem() {
  uint16_t fr = FreeStack();
  Serial.print(F("RAM: ")); Serial.print(fr);
  Serial.print(F("/2048 (used:")); Serial.print(2048 - fr);
  Serial.print(F(") "));
  Serial.println(fr >= SRAM_WARN_FREE_BYTES ? F("OK")
                 : (fr >= SRAM_CRITICAL_FREE_BYTES ? F("LOW") : F("CRIT!")));
}
#endif

static void logRamBudget(const __FlashStringHelper* phase) {
  uint16_t freeBytes = FreeStack();
  LOG_PRINT(phase);
  LOG_PRINT_F(" RAM free=");
  LOG_PRINT(freeBytes);

  if (freeBytes < SRAM_CRITICAL_FREE_BYTES) {
    LOG_PRINTLN_F(" CRITICAL");
  } else if (freeBytes < SRAM_WARN_FREE_BYTES) {
    LOG_PRINTLN_F(" LOW");
  } else {
    LOG_PRINTLN_F(" OK");
  }
}

// Cold Boot SD Initialization with Retry Logic
bool initSD() {
  const uint8_t SD_RETRY_COUNT = 3;
  const uint16_t SD_RETRY_DELAY_MS = 200;

  for (uint8_t retry = 0; retry < SD_RETRY_COUNT; retry++) {
    if (sd.begin(chipSelect, SPI_HALF_SPEED)) {
      delay(50);  // Let card stabilize after init
      if (retry > 0) {
        LOG_PRINT_F("SD: OK after ");
        LOG_PRINT(retry + 1);
        LOGI(SD, " attempts");
      }
      return true;
    }

    LOG_PRINT_F("SD: Init attempt ");
    LOG_PRINT(retry + 1);
    LOG_PRINT_F("/");
    LOG_PRINT(SD_RETRY_COUNT);
    LOG_PRINT_F(" failed ec=0x");
    LOG_HEX(sd.sdErrorCode());
    LOG_PRINT_F(" ed=0x");
    LOG_PRINTLN(sd.sdErrorData());

    if (retry < SD_RETRY_COUNT - 1) {
      delay(SD_RETRY_DELAY_MS);
    }
  }

  return false;
}

static bool ensureRuntimeReady() {
  if (runtimeReady) {
    return true;
  }

  bool sdSuccess = initSD();
  printSDStatus(sdSuccess);
  if (!sdSuccess) {
    return false;
  }

  cartApi.Init();
  runtimeReady = true;
  return true;
}

// SD error recovery: reinitialize card + resync dirFunc
// Call this after any SD error (write timeout, etc.) to restore working state.
// Critical for C64 service: the C64 can't know the SD is in a bad state.
bool recoverSD() {
  dirFunc.CloseDirHandle();
  delay(50);
  if (!sd.begin(chipSelect, SPI_HALF_SPEED)) {
    // Retry after longer delay
    delay(200);
    if (!sd.begin(chipSelect, SPI_HALF_SPEED)) {
      LOGE(SD, "SD recover FAIL");
      return false;
    }
  }
  dirFunc.ForceReset();
  LOGI(SD, "Recovered");
  return true;
}

void printStartupBanner() {
  LOGI(SYS, "EasySD v3.1.3");
}

void printSDStatus(bool sdInitSuccess) {
  if (sdInitSuccess) {
    LOGI(SD, "SD OK");
    logRamBudget(F("Boot"));
  } else {
    LOGE(SD, "SD FAIL - check card");
  }
  LOG_NEWLINE();
}

#ifdef EASYSD_DEBUG_SERIAL
// Help System (DEBUG mode only)
void printHelp() {
  Serial.println(F("h:Help m:Mem"));
  #ifdef EASYSD_SELFTEST
  Serial.println(F("d:CD r:Root l:List p:Stat T:Test"));
  #endif
  #ifdef EASYSD_PROTOCOL_TEST
  Serial.println(F("F:FileDump G:GameHeader B:BoundaryDump"));
  #endif
}
#endif // EASYSD_DEBUG_SERIAL

void setup() {
  cartInterface.Init();   // IOSetup: EXROM=HIGH, /RESET=LOW — C64 held in reset

  LOG_BEGIN(57600);
  printStartupBanner();
  LOGI(SYS, "Boot: hold reset");

  pinMode(chipSelect, OUTPUT);
  digitalWrite(chipSelect, HIGH);
  SPI.begin();

  // IO2 receive not armed during cold boot — listening starts after TransferMenu()
  // which is only called on explicit SEL button press, not at boot.
  cartInterface.ResetReceive();

  // SD card power-up settling time. Without a bootloader the AVR reaches this
  // point within ~1ms of power-on; SD cards need up to 300ms before accepting
  // SPI commands (SD Physical Layer spec, section 6.4.1).
  delay(300);

  LOGI(SYS, "Boot: init SD");
  bootState = BOOT_INIT_SD;
  bool sdOk = initSD();
  printSDStatus(sdOk);

  if (sdOk) {
    // Release C64 to BASIC BEFORE cartApi.Init() so the C64 boot edge happens
    // while the SPI/SD bus is completely idle (no directory scan in progress).
    // cartApi.Init() runs immediately after, still in setup(), well within the
    // 500ms boot-guard window before SEL can fire.
#ifdef EASYSD_DEBUG_SERIAL
    Serial.print(F("[BOOT] pre-release t=")); Serial.println(millis());
#endif
    LOGI(SYS, "Boot: release to BASIC");
    bootState = BOOT_RELEASE_BASIC;
    cartInterface.ReleaseColdBootToBasic();
#ifdef EASYSD_DEBUG_SERIAL
    Serial.print(F("[BOOT] post-release t=")); Serial.println(millis());
#endif

    LOGI(SYS, "Boot: init runtime");
    bootState = BOOT_INIT_RUNTIME;
    cartApi.Init();
    runtimeReady = true;

    bootState = RUNNING_READY;
    LOGI(SYS, "Boot: ready (BASIC)");
    logRamBudget(F("Ready"));
  } else {
    // SD failed: release C64 to BASIC so the user isn't stuck at a black screen.
    // Use the cold-boot release path here too — same long-LOW-dwell condition.
    // SEL button will retry SD init + TransferMenu on press.
#ifdef EASYSD_DEBUG_SERIAL
    Serial.print(F("[BOOT] SD-fail pre-release t=")); Serial.println(millis());
#endif
    cartInterface.ReleaseColdBootToBasic();
    bootState = BOOT_ERROR;
    LOGE(SYS, "Boot: SD fail, released");
  }

  suppressButtonsFor(BUTTON_BOOT_GUARD_MS);
  rearmSelTracking();
}


void loop() {
  if ((long)(millis() - buttonEnableAtMs) < 0) {
    state = stateNone;
    pressTimeMs = 0;
  } else {
    bool selReleased = serviceSelReleased();

    if (!selReleased && state == stateNone) {
      state = statePressed;
      pressTimeMs = millis();
    }

    if (selReleased && state == statePressed) {
      unsigned long elapsedMs = millis() - pressTimeMs;
      state = stateNone;

      // Ignore switch bounce / accidental micro taps.
      if (elapsedMs >= BUTTON_DEBOUNCE_MS) {
        if (elapsedMs > BUTTON_LONG_PRESS_MS) {
          // Long press: release strictly after the 1000 ms threshold -> BASIC.
          LOGI(SYS, "SEL long press -> reset");
          cartApi.ResetNoCartridge();
        } else {
          // Short press: release at or before the 1000 ms threshold -> menu.
          LOGI(SYS, "SEL press -> menu");
          if (ensureRuntimeReady()) {
            cartApi.TransferMenu();
            bootState = RUNNING_READY;
          }
        }
        suppressButtonsFor(BUTTON_POST_ACTION_GUARD_MS);
        rearmSelTracking();
      }
    }
  }

  // Handle API only when runtime is ready — listening is started by TransferMenu()
  // which is called on SEL press, not at cold boot.
  if (runtimeReady) {
    cartApi.HandleApi();
  }

  #ifdef EASYSD_DEBUG_SERIAL
  // Serial monitor commands (DEBUG mode only)
  while (Serial.available() > 0) {
      char data=(char)Serial.read();
      switch(data) {
          case 'h' : printHelp(); break;
          case 'm' : ShowMem(); break;

          #ifdef EASYSD_SELFTEST
          case 'd' : testDirectoryNavigation(); break;
          case 'r' : testResetToRoot(); break;
          case 'p' : testPrintCurrentPath(); break;
          case 'l' : testListDirectory(); break;
          case 'T' : testRunAll(); break;
          #endif

          #ifdef EASYSD_PROTOCOL_TEST
          case 'F' : testFileDump(); break;
          case 'G' : testGameHeader(); break;
          case 'B' : testBoundaryDump(); break;
          #endif
      }
  }
  #endif
}

#ifdef EASYSD_SELFTEST
// ========================================================================
// Self-test & interactive directory test functions (EASYSD_SELFTEST only)
// These are gated separately from EASYSD_DEBUG_SERIAL because they consume
// ~2KB flash. Enable via build.py --selftest or #define EASYSD_SELFTEST.
// ========================================================================

void testDirectoryNavigation() {
  Serial.println(F("Dir:"));
  while (Serial.available() == 0) { delay(10); }
  char dn[48];
  uint8_t i = 0;
  while (i < 47) {
    if (Serial.available()) {
      char ch = Serial.read();
      if (ch == '\n' || ch == '\r') break;
      dn[i++] = ch;
    }
  }
  dn[i] = 0;
  // trim trailing spaces
  while (i > 0 && dn[i-1] == ' ') dn[--i] = 0;
  if (!i) return;

  if (dirFunc.ChangeDirectoryBasename(dn)) {
    dirFunc.Prepare();
    Serial.print(F("Path: ")); Serial.println(dirFunc.currentPath);
    Serial.print(F("Items: ")); Serial.println(dirFunc.GetCount());
  } else {
    Serial.print(F("Err: ")); Serial.println(dn);
  }
}

void testResetToRoot() {
  dirFunc.ForceReset();
  Serial.print(F("Root: "));
  Serial.print(dirFunc.GetCount());
  Serial.println(F(" items"));
}

void testPrintCurrentPath() {
  Serial.print(F("Path: ")); Serial.println(dirFunc.GetCurrentPath());
  Serial.print(F("Depth: ")); Serial.println(dirFunc.pathDepth);
  Serial.print(F("Items: ")); Serial.println(dirFunc.GetCount());
  Serial.print(F("RAM: ")); Serial.println(FreeStack());
}

void testListDirectory() {
  dirFunc.Prepare();
  Serial.println(dirFunc.currentPath);
  int ic = 0, dc = 0;
  while (dirFunc.Iterate()) {
    ic++;
    Serial.print(dirFunc.IsDirectory ? F("[D] ") : F("[ ] "));
    Serial.println(dirFunc.currentFileName);
    if (dirFunc.IsDirectory) dc++;
  }
  Serial.print(ic); Serial.print(F(" items (")); Serial.print(dc); Serial.println(F(" dirs)"));
}

// ========================================================================
// Self-test: each test is a SEPARATE function so stack is fully freed
// between tests. No static File - each function uses local File that
// lives only for the duration of that test. Max 32-64 bytes local,
// monitor FreeStack() > 300.
// ========================================================================

// Helper: print [T] tag + test name + PASS/FAIL
static void tResult(const __FlashStringHelper* name, bool ok) {
  Serial.print(F("[T] "));
  Serial.print(name);
  Serial.println(ok ? F(": PASS") : F(": FAIL"));
}

// Test 1: Open, read 16 bytes, verify content, close
static bool tOpenReadClose() {
  File f = sd.open("TESTDATA.BIN", FILE_READ);
  if (!f) return false;
  uint8_t buf[16];
  int n = f.read(buf, 16);
  f.close();
  if (n != 16 || buf[0] != 0x00 || buf[15] != 0x0F) {
    Serial.print(F("  n=")); Serial.print(n);
    Serial.print(F(" [0]=0x")); Serial.print(buf[0], HEX);
    Serial.print(F(" [15]=0x")); Serial.println(buf[15], HEX);
    return false;
  }
  return true;
}

// Test 2: Open, seek to 0x80, read 1 byte, verify
static bool tSeek() {
  File f = sd.open("TESTDATA.BIN", FILE_READ);
  if (!f) return false;
  f.seekSet(0x80);
  uint8_t b;
  bool ok = (f.read(&b, 1) == 1 && b == 0x80);
  f.close();
  return ok;
}

// Test 3: Non-existent file must fail to open
static bool tOpenNoExist() {
  File f = sd.open("_NOEX.XYZ", FILE_READ);
  bool ok = !f;
  if (f) f.close();
  return ok;
}

// Test 4: Write 16 bytes, read back, verify, delete
// Uses O_WRONLY for write phase (SdFat best practice), O_RDONLY for verify.
// Reports detailed error info for diagnosing SD card/hardware issues.
static bool tWriteDelete() {
  if (sd.exists("_TT.TMP")) { sd.remove("_TT.TMP"); delay(50); }

  // Phase 1: Write
  delay(50);
  File f = sd.open("_TT.TMP", O_WRONLY | O_CREAT);
  if (!f) {
    Serial.print(F("  open err=0x")); Serial.println(sd.sdErrorCode(), HEX);
    return false;
  }
  uint8_t buf[16];
  for (uint8_t j = 0; j < 16; j++) buf[j] = j + 0x40;
  size_t wr = f.write(buf, 16);
  if (wr != 16 || f.getWriteError()) {
    Serial.print(F("  wr=")); Serial.print(wr);
    Serial.print(F(" we=")); Serial.print(f.getWriteError());
    Serial.print(F(" se=0x")); Serial.println(sd.sdErrorCode(), HEX);
    f.close();
    return false;
  }
  if (!f.sync()) {
    Serial.print(F("  sync err=0x")); Serial.println(sd.sdErrorCode(), HEX);
    f.close();
    return false;
  }
  f.close();

  // Phase 2: Read back and verify
  delay(50);
  f = sd.open("_TT.TMP", FILE_READ);
  if (!f) { return false; }
  int n = f.read(buf, 16);
  f.close();
  if (n != 16 || buf[0] != 0x40 || buf[15] != 0x4F) {
    Serial.print(F("  v n=")); Serial.print(n);
    Serial.print(F(" [0]=0x")); Serial.print(buf[0], HEX);
    Serial.print(F(" [15]=0x")); Serial.println(buf[15], HEX);
    sd.remove("_TT.TMP");
    return false;
  }

  // Phase 3: Delete
  if (!sd.remove("_TT.TMP")) {
    Serial.print(F("  del err=0x")); Serial.println(sd.sdErrorCode(), HEX);
    return false;
  }
  return true;
}

// Test 5: 20x open/read/close cycle, check RAM stability
static bool tMemLoop() {
  for (uint8_t i = 0; i < 20; i++) {
    File f = sd.open("TESTDATA.BIN", FILE_READ);
    if (!f) {
      Serial.print(F("  fail@")); Serial.println(i);
      return false;
    }
    uint8_t buf[16];
    f.read(buf, 16);
    f.close();
  }
  return true;
}

// Test 6: Root directory listing via ForceReset
static bool tRootList() {
  dirFunc.ForceReset();
  return dirFunc.GetCount() > 0;
}

// Test 7: cd into TESTDIR, verify items, go back
static bool tDirNav() {
  // Diagnostic: check if TESTDIR is visible before chdir
  bool ex = sd.exists("TESTDIR");
  Serial.print(F("  exists=")); Serial.print(ex);
  Serial.print(F(" depth=")); Serial.print(dirFunc.pathDepth);
  Serial.print(F(" path=")); Serial.println(dirFunc.currentPath);
  if (!ex) {
    Serial.print(F("  se=0x")); Serial.println(sd.sdErrorCode(), HEX);
    return false;
  }
  if (!dirFunc.ChangeDirectoryBasename("TESTDIR")) {
    Serial.print(F("  cd se=0x")); Serial.println(sd.sdErrorCode(), HEX);
    return false;
  }
  dirFunc.Prepare();
  bool ok = dirFunc.GetCount() > 0;
  dirFunc.GoBack();
  return ok;
}

// Helper: recover SD after any failure to prevent cascading errors.
// On breadboard/prototype hardware, SPI errors corrupt SdFat state.
// In production (C64 cartridge), this ensures the "drive" stays online.
static void tRecover() {
  Serial.println(F("[T] SD recover..."));
  recoverSD();
}

// 'T' - run all self-tests, each in its own function call
void testRunAll() {
  uint8_t pass = 0, fail = 0;
  uint16_t ram0 = FreeStack();
  Serial.println(F("[T] START"));

  tResult(F("SD_INIT"), true); pass++;

  bool ok;
  delay(50);
  ok = tOpenReadClose(); tResult(F("OPEN_RD_CL"), ok); ok ? pass++ : fail++;
  if (!ok) tRecover();

  delay(50);
  ok = tSeek();          tResult(F("SEEK"), ok);        ok ? pass++ : fail++;
  if (!ok) tRecover();

  delay(50);
  ok = tOpenNoExist();   tResult(F("OPEN_NOEX"), ok);   ok ? pass++ : fail++;

  delay(100);
  ok = tWriteDelete();   tResult(F("WR_DEL"), ok);      ok ? pass++ : fail++;
  if (!ok) tRecover();

  delay(50);
  { uint16_t rs = FreeStack();
    ok = tMemLoop();
    uint16_t re = FreeStack();
    Serial.print(F("[T] MEM_LOOP: "));
    if (ok) { Serial.print(F("PASS ")); Serial.print(rs);
      Serial.print(F("->")); Serial.println(re); pass++; }
    else { Serial.println(F("FAIL")); fail++; tRecover(); } }

  delay(50);
  ok = tRootList();
  Serial.print(F("[T] ROOT_LIST: ")); Serial.print(ok ? F("PASS (") : F("FAIL ("));
  Serial.print(dirFunc.GetCount()); Serial.println(')');
  ok ? pass++ : fail++;
  if (!ok) tRecover();

  delay(50);
  ok = tDirNav(); tResult(F("DIR_NAV"), ok); ok ? pass++ : fail++;

  Serial.print(F("[T] END: ")); Serial.print(pass); Serial.print('/');
  Serial.print(pass+fail); Serial.print(F(" RAM:")); Serial.print(ram0);
  Serial.print(F("->")); Serial.println(FreeStack());
  dirFunc.ForceReset();
}

#endif // EASYSD_SELFTEST

// ============================================================================
// Protocol Echo Test Functions (EASYSD_PROTOCOL_TEST mode only)
// Redirect SD file data to Serial.write() for PC-side byte verification.
// ============================================================================

#ifdef EASYSD_PROTOCOL_TEST

// Helper: read filename from serial into buf (max maxLen chars + null).
// Blocks until '\n' or '\r' received, or buf is full.
static void ptReadFilename(char *buf, uint8_t maxLen) {
  uint8_t i = 0;
  while (i < maxLen) {
    while (!Serial.available()) {}
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') break;
    buf[i++] = ch;
  }
  buf[i] = 0;
}

// 'F' - File dump: outputs [FD] SIZE=N, then N raw bytes, then [FD] END
void testFileDump() {
  char name[13];
  ptReadFilename(name, 12);

  File f = sd.open(name, FILE_READ);
  if (!f) { Serial.println(F("[FD] ERR")); return; }

  Serial.print(F("[FD] SIZE="));
  Serial.println(f.size());

  uint8_t buf[16];
  int n;
  while ((n = f.read(buf, sizeof(buf))) > 0) {
    Serial.write(buf, n);
  }
  f.close();
  Serial.println(F("[FD] END"));
}

// 'G' - Game header: outputs [GH] LOAD=$XXXX END=$XXXX PAGES=N TYPE=1 SIZE=N P2TK=Y/N
// Mirrors TransferGame() + SendHeader() header calculation (CartApi.cpp).
void testGameHeader() {
  char name[13];
  ptReadFilename(name, 12);

  File f = sd.open(name, FILE_READ);
  if (!f) { Serial.println(F("[GH] ERR")); return; }

  uint32_t fileSize = f.size();
  uint8_t loadLow  = (uint8_t)f.read();
  uint8_t loadHigh = (uint8_t)f.read();
  f.close();

  uint16_t startAddr    = (uint16_t)loadLow | ((uint16_t)loadHigh << 8);
  long transferLength   = (long)fileSize - 2;
  long padBytes         = (transferLength % 256 == 0) ? 0L : 256L - transferLength % 256;
  uint8_t transferPages = (uint8_t)(transferLength / 256 + (padBytes > 0 ? 1 : 0));
  long endAddress       = (long)startAddr + transferLength + 1;
  bool p2tk             = (endAddress > 0xC002L);

  Serial.print(F("[GH] LOAD=$")); Serial.print(startAddr, HEX);
  Serial.print(F(" END=$"));      Serial.print((uint16_t)endAddress, HEX);
  Serial.print(F(" PAGES="));     Serial.print(transferPages, DEC);
  Serial.print(F(" TYPE=1 SIZE="));Serial.print(fileSize, DEC);
  Serial.print(F(" P2TK="));      Serial.println(p2tk ? F("Y") : F("N"));
}

// 'B' - Boundary dump: outputs 64B chunks with [BD] CHUNK=N SZ=M markers,
// then raw bytes, then [BD] END. Tests SD read correctness across 64B boundaries.
void testBoundaryDump() {
  char name[13];
  ptReadFilename(name, 12);

  File f = sd.open(name, FILE_READ);
  if (!f) { Serial.println(F("[BD] ERR")); return; }

  uint32_t total = f.size();
  uint32_t pos   = 0;
  uint8_t  chunk = 0;

  while (pos < total) {
    uint8_t cSz = (total - pos > 64) ? 64 : (uint8_t)(total - pos);

    Serial.print(F("[BD] CHUNK=")); Serial.print(chunk, DEC);
    Serial.print(F(" SZ="));        Serial.println(cSz, DEC);

    uint8_t buf[16];
    uint8_t remaining = cSz;
    while (remaining > 0) {
      uint8_t toRead = (remaining < 16) ? remaining : 16;
      int n = f.read(buf, toRead);
      if (n <= 0) { pos = total; break; }  // SD error: abort outer loop
      Serial.write(buf, n);
      remaining -= (uint8_t)n;
      pos       += (uint32_t)n;
    }
    chunk++;
  }

  f.close();
  Serial.println(F("[BD] END"));
}

#endif // EASYSD_PROTOCOL_TEST

