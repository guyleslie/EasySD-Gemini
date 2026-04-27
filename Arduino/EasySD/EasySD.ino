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
}
