#include "EasySD.h"
#include "CartInterface.h"
#include "CartApi.h"
#include "EasySDLog.h"
#include <Arduino.h>
#include <SPI.h>
#include <SdFat.h>

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

// Cold Boot SD Initialization with Retry Logic
bool initSD() {
  const uint8_t SD_RETRY_COUNT = 3;
  const uint16_t SD_RETRY_DELAY_MS = 200;

  for (uint8_t retry = 0; retry < SD_RETRY_COUNT; retry++) {
    if (sd.begin(chipSelect, SPI_FULL_SPEED)) {
      delay(50);  // Let card stabilize after init
      return true;
    }

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
  if (!sd.begin(chipSelect, SPI_FULL_SPEED)) {
    // Retry after longer delay
    delay(200);
    if (!sd.begin(chipSelect, SPI_FULL_SPEED)) {
      LOGE(SD, "SD recover FAIL");
      return false;
    }
  }
  dirFunc.ForceReset();
  return true;
}

void printSDStatus(bool sdInitSuccess) {
  if (!sdInitSuccess) {
    LOG_LOAD_SD_FAIL();
    LOGE(SD, "SD FAIL - check card");
  }
}

void setup() {
  // IRQHack64-style boot: configure the cartridge interface immediately, leave
  // /RESET released, and let the C64 boot while the AVR initializes SD.
  cartInterface.Init();

  LOG_BEGIN(57600);
  LOGI(SYS, "EasySD DEBUG boot");

  pinMode(chipSelect, OUTPUT);
  digitalWrite(chipSelect, HIGH);
  SPI.begin();

  // SD Physical Layer spec section 6.4.1: cards need up to 300ms after power-up
  // before accepting SPI commands. C64 boots to BASIC in parallel during this wait.
  delay(300);

  bool sdOk = initSD();
  printSDStatus(sdOk);

  if (sdOk) {
    cartApi.Init();
    runtimeReady = true;
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
          cartApi.ResetNoCartridge();
        } else {
          // Short press: release at or before the 1000 ms threshold -> menu.
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
