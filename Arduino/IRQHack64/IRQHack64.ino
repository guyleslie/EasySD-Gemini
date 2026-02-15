#include "IrqHack64.h"
#include "CartInterface.h"
#include "CartApi.h"
#include <Arduino.h>
#include <EEPROM.h>
#include <SPI.h>
#include <SdFat.h>
// #include <SdFatUtil.h>  // Removed: Not available in SdFat 2.x
#include <FreeStack.h>  // SdFat 2.x: For FreeStack() function


SdFat sd;
DirFunction dirFunc;
CartApi cartApi;
CartInterface cartInterface;

const unsigned char stateNone = 0;
const unsigned char statePressed = 1;
const unsigned char stateReleased = 2;


const unsigned char stateBoot = 0;
const unsigned char stateMenu = 1;
const unsigned char stateGame = 2;

/*
volatile unsigned char transferMode = 2;
*/

unsigned char  state = stateNone;
uint16_t pressTime = 0;

//unsigned char cartridgeState = stateBoot;

const unsigned char chipSelect = 10;

void ShowMem() {
#ifdef EASYSD_DEBUG_SERIAL
  uint16_t freeRAM = FreeStack();
  uint16_t usedRAM = 2048 - freeRAM;

  Serial.println(F("Memory Status"));
  Serial.println(F("----------------------------"));
  Serial.print(F("Total SRAM:  2048 bytes"));
  Serial.println();
  Serial.print(F("Used:        "));
  Serial.print(usedRAM);
  Serial.print(F(" bytes ("));
  Serial.print((usedRAM * 100) / 2048);
  Serial.println(F("%)"));
  Serial.print(F("Free:        "));
  Serial.print(freeRAM);
  Serial.print(F(" bytes ("));
  Serial.print((freeRAM * 100) / 2048);
  Serial.println(F("%)"));
  Serial.println(F("----------------------------"));

  // Status indicator
  Serial.print(F("Status: "));
  if (freeRAM > 400) {
    Serial.println(F("Normal"));
  } else if (freeRAM > 300) {
    Serial.println(F("Low (caution)"));
  } else {
    Serial.println(F("Critical!"));
  }
  Serial.println();
#endif
}

// SPRINT 6: Cold Boot SD Initialization with Retry Logic
bool initSD() {
  const uint8_t SD_RETRY_COUNT = 3;
  const uint16_t SD_RETRY_DELAY_MS = 200;

  for (uint8_t retry = 0; retry < SD_RETRY_COUNT; retry++) {
    if (sd.begin(chipSelect, SPI_HALF_SPEED)) {
      #ifdef EASYSD_DEBUG_SERIAL
      if (retry > 0) {
        Serial.print(F("SD: OK after "));
        Serial.print(retry + 1);
        Serial.println(F(" attempts"));
      }
      #endif
      return true;
    }

    #ifdef EASYSD_DEBUG_SERIAL
    Serial.print(F("SD: Init attempt "));
    Serial.print(retry + 1);
    Serial.print(F("/"));
    Serial.print(SD_RETRY_COUNT);
    Serial.println(F(" failed"));
    #endif

    if (retry < SD_RETRY_COUNT - 1) {
      delay(SD_RETRY_DELAY_MS);
    }
  }

  return false;
}

#ifdef EASYSD_DEBUG_SERIAL
// SPRINT 6: Professional Startup Banner (DEBUG mode only)
void printStartupBanner() {
  Serial.println(F("================================"));
  Serial.println(F(" EasySD IRQHack64 v2.1.0"));
  Serial.println(F(" SdFat 2.3.0 | Arduino Nano"));
  Serial.println(F("================================"));
  Serial.println();
}

void printSDStatus(bool sdInitSuccess) {
  if (sdInitSuccess) {
    Serial.println(F("SD OK"));
    Serial.print(F("RAM: "));
    Serial.println(FreeStack());
    Serial.println(F("Type 'h' for help"));
  } else {
    Serial.println(F("SD FAIL - check card"));
  }
  Serial.println();
}

// SPRINT 6: Help System (DEBUG mode only)
void printHelp() {
  Serial.println(F("Commands:"));
  Serial.println(F("  h  Help"));
  Serial.println(F("  d  Navigate"));
  Serial.println(F("  r  Root"));
  Serial.println(F("  l  List"));
  Serial.println(F("  p  Status"));
  Serial.println(F("  m  Memory"));
  Serial.println();
}
#endif // EASYSD_DEBUG_SERIAL

void setup() {
  cartInterface.Init();

  #ifdef EASYSD_DEBUG_SERIAL
  Serial.begin(57600);
  // SPRINT 6: Professional startup banner
  printStartupBanner();
  #endif

  // SPRINT 1: Explicit SPI initialization for SD card
  pinMode(chipSelect, OUTPUT);     // CS pin must be OUTPUT
  digitalWrite(chipSelect, HIGH);  // Deselect SD card initially
  SPI.begin();                     // Initialize SPI bus

  // SPRINT 6: SD init with retry logic for cold boot reliability
  bool sdSuccess = initSD();

  #ifdef EASYSD_DEBUG_SERIAL
  // SPRINT 6: Print SD status with user-friendly messages
  printSDStatus(sdSuccess);
  #endif

  // POST-SPRINT6: cartApi.Init() handles dirFunc.ReInit() + Prepare() internally
  // No need to call them explicitly here (removes duplicate init logging)
  cartApi.Init();
}


void SerialTestTerminal() {
  while(1) {
    cartApi.HandleApi();
  }
}

void loop() {
  cartApi.HandleApi();
  
  if (!digitalRead(SEL) && state == stateNone) {
    state = statePressed;
    pressTime = millis()/100;
  }

  uint16_t elapsed;
  if (digitalRead(SEL) && state == statePressed) {
    state = stateReleased;          
    elapsed = millis()/100 - pressTime;
    if (elapsed >5) {
      cartApi.ResetNoCartridge();
      //cartridgeState = stateBoot;      
    } else {
      cartApi.TransferMenu();
      //cartridgeState = stateMenu;
    }
  }
  
  if (state == stateReleased) {
    if ( (millis()/100 - pressTime)>15) {
      state = stateNone;
      elapsed = 0;
      pressTime = 0;
    }
  }

  #ifdef EASYSD_DEBUG_SERIAL
  // Serial monitor commands (DEBUG mode only)
  while (Serial.available() > 0) {
      char data=(char)Serial.read();
      switch(data) {
          // SPRINT 1: Legacy menu disabled to save ~150 bytes
          // Uncomment after Sprint 1 for full functionality:
          //case '1' : cartApi.ReceiveFile(); break;
          //case '2' : cartApi.TransferMenu(); break;
          //case '3' : cartInterface.ResetC64(); break;
          //case '4' : cartApi.ResetNoCartridge(); break;
          //case '5' : cartApi.UpdateFile(); break;
          //case '6' : SerialTestTerminal(); break;

          // SPRINT 6: User-friendly commands
          case 'h' : printHelp(); break;

          // SPRINT 1: Directory Navigation Testing
          case 'd' : testDirectoryNavigation(); break;
          case 'r' : testResetToRoot(); break;
          case 'p' : testPrintCurrentPath(); break;
          case 'l' : testListDirectory(); break;
          case 'm' : ShowMem(); break;
      }
  }
  #endif
}

#ifdef EASYSD_DEBUG_SERIAL
// ========================================================================
// SPRINT 1: Directory Navigation Test Functions (DEBUG mode only)
// ========================================================================

void testDirectoryNavigation() {
  Serial.println(F("Dir name:"));

  while (Serial.available() == 0) { delay(10); }
  String input = Serial.readStringUntil('\n');
  input.trim();

  if (input.length() > 0) {
    char dirname[64];
    input.toCharArray(dirname, 64);

    bool result = dirFunc.ChangeDirectoryBasename(dirname);
    if (result) {
      dirFunc.Prepare();
      Serial.print(F("Path: "));
      Serial.println(dirFunc.currentPath);
      Serial.print(F("Items: "));
      Serial.println(dirFunc.GetCount());
    } else {
      Serial.print(F("Error: "));
      Serial.println(dirname);
    }
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
  // SPRINT 6: Always prepare before listing
  dirFunc.Prepare();

  Serial.println(dirFunc.currentPath);
  Serial.println(F("----------------------------"));

  int itemCount = 0;
  int dirCount = 0;

  while (dirFunc.Iterate()) {
    if (!dirFunc.IsHidden) {
      itemCount++;
      if (dirFunc.IsDirectory) {
        Serial.print(F("[D] "));
        dirCount++;
      } else {
        Serial.print(F("[ ] "));
      }
      Serial.println(dirFunc.CurrentFileName.value);
    }
  }

  Serial.println(F("----------------------------"));
  Serial.print(itemCount);
  Serial.print(F(" items ("));
  Serial.print(dirCount);
  Serial.println(F(" dirs)"));
}
#endif // EASYSD_DEBUG_SERIAL

