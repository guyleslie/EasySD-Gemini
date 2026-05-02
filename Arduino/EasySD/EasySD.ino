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

// irqhack-style cold boot: AVR does NOT hold C64 in /RESET. The C64 cold-boots
// to BASIC on its own RC; AVR initializes SD in parallel and is ready by the
// time the user presses SEL. Menu loads only on explicit SEL press.
const unsigned char stateNone = 0;
const unsigned char statePressed = 1;

unsigned char state = stateNone;
unsigned long pressTimeMs = 0;
unsigned long buttonEnableAtMs = 0;
bool runtimeReady = false;
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
  // IOSetup leaves /RESET HIGH (released) and EXROM HIGH (cartridge hidden).
  // The C64 boots to BASIC from its own RC reset while AVR initializes SD.
  cartInterface.Init();

  LOG_BEGIN(57600);
  printStartupBanner();
  LOGI(SYS, "Boot: irqhack-style (no reset hold)");

  pinMode(chipSelect, OUTPUT);
  digitalWrite(chipSelect, HIGH);
  SPI.begin();

  // IO2 receive not armed during cold boot — listening starts after TransferMenu()
  // which is only called on explicit SEL button press, not at boot.
  cartInterface.ResetReceive();

  // SD Physical Layer spec section 6.4.1: cards need up to 300ms after power-up
  // before accepting SPI commands. C64 boots to BASIC in parallel during this wait.
  delay(300);

  LOGI(SYS, "Boot: init SD");
  bool sdOk = initSD();
  printSDStatus(sdOk);

  if (sdOk) {
    cartApi.Init();
    runtimeReady = true;
    LOGI(SYS, "Boot: ready (BASIC)");
    logRamBudget(F("Ready"));
  } else {
    LOGE(SYS, "Boot: SD fail");
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
