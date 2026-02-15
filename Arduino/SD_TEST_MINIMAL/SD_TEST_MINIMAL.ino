/*
 * MINIMAL SD CARD TEST
 * Arduino Nano + SD Card Module
 *
 * Wiring:
 * D10 -> CS
 * D11 -> MOSI
 * D12 -> MISO
 * D13 -> SCK
 * 5V  -> VCC
 * GND -> GND
 */

#include <SPI.h>
#include <SdFat.h>

const int chipSelect = 10;
SdFat sd;

void setup() {
  Serial.begin(57600);
  while (!Serial) { delay(10); }  // Wait for serial

  Serial.println(F("================================="));
  Serial.println(F("MINIMAL SD CARD TEST"));
  Serial.println(F("================================="));

  // Test 1: Pin configuration
  Serial.println(F("\n[TEST 1] Pin Configuration..."));
  pinMode(chipSelect, OUTPUT);
  digitalWrite(chipSelect, HIGH);
  pinMode(11, OUTPUT);  // MOSI
  pinMode(13, OUTPUT);  // SCK
  pinMode(12, INPUT);   // MISO
  Serial.println(F("  CS (D10): OUTPUT, HIGH"));
  Serial.println(F("  MOSI (D11): OUTPUT"));
  Serial.println(F("  MISO (D12): INPUT"));
  Serial.println(F("  SCK (D13): OUTPUT"));
  Serial.println(F("  [PASS]"));

  // Test 2: SPI initialization
  Serial.println(F("\n[TEST 2] SPI Initialization..."));
  SPI.begin();
  Serial.println(F("  SPI.begin() called"));
  Serial.println(F("  [PASS]"));

  // Test 3: SD card init with FULL SPEED
  Serial.println(F("\n[TEST 3] SD Init (FULL SPEED)..."));
  if (sd.begin(chipSelect, SPI_FULL_SPEED)) {
    Serial.println(F("  [PASS] SD OK at FULL SPEED!"));
  } else {
    Serial.println(F("  [FAIL] Full speed failed"));
    Serial.print(F("  Error: 0x"));
    Serial.print(sd.card()->errorCode(), HEX);
    Serial.print(F(",0x"));
    Serial.println(sd.card()->errorData(), HEX);
  }

  // Test 4: SD card init with HALF SPEED
  Serial.println(F("\n[TEST 4] SD Init (HALF SPEED)..."));
  if (sd.begin(chipSelect, SPI_HALF_SPEED)) {
    Serial.println(F("  [PASS] SD OK at HALF SPEED!"));
  } else {
    Serial.println(F("  [FAIL] Half speed failed"));
    Serial.print(F("  Error: 0x"));
    Serial.print(sd.card()->errorCode(), HEX);
    Serial.print(F(",0x"));
    Serial.println(sd.card()->errorData(), HEX);
  }

  // Test 5: SD card init with QUARTER SPEED (slowest)
  Serial.println(F("\n[TEST 5] SD Init (QUARTER SPEED)..."));
  if (sd.begin(chipSelect, SPI_QUARTER_SPEED)) {
    Serial.println(F("  [PASS] SD OK at QUARTER SPEED!"));

    // Show card info
    Serial.println(F("\n[CARD INFO]"));
    Serial.print(F("  Type: "));
    switch (sd.card()->type()) {
      case SD_CARD_TYPE_SD1:  Serial.println(F("SD1")); break;
      case SD_CARD_TYPE_SD2:  Serial.println(F("SD2")); break;
      case SD_CARD_TYPE_SDHC: Serial.println(F("SDHC")); break;
      default: Serial.println(F("Unknown")); break;
    }

    uint32_t size = sd.card()->cardSize();
    Serial.print(F("  Size: "));
    Serial.print(size * 0.000512);
    Serial.println(F(" MB"));

  } else {
    Serial.println(F("  [FAIL] Quarter speed failed"));
    Serial.print(F("  Error: 0x"));
    Serial.print(sd.card()->errorCode(), HEX);
    Serial.print(F(",0x"));
    Serial.println(sd.card()->errorData(), HEX);
  }

  // Test 6: Manual SPI test - send CMD0
  Serial.println(F("\n[TEST 6] Manual SPI Test..."));
  Serial.println(F("  Sending CMD0 manually..."));

  digitalWrite(chipSelect, LOW);
  delay(1);

  SPI.transfer(0x40);  // CMD0
  SPI.transfer(0x00);  // ARG
  SPI.transfer(0x00);
  SPI.transfer(0x00);
  SPI.transfer(0x00);
  SPI.transfer(0x95);  // CRC

  // Wait for response
  uint8_t response = 0xFF;
  for (int i = 0; i < 10; i++) {
    response = SPI.transfer(0xFF);
    if (response != 0xFF) break;
  }

  digitalWrite(chipSelect, HIGH);

  Serial.print(F("  Response: 0x"));
  Serial.println(response, HEX);
  if (response == 0x01) {
    Serial.println(F("  [PASS] SD card responded!"));
  } else if (response == 0xFF) {
    Serial.println(F("  [FAIL] No response (check wiring!)"));
  } else {
    Serial.println(F("  [WARN] Unexpected response"));
  }

  Serial.println(F("\n================================="));
  Serial.println(F("TEST COMPLETE"));
  Serial.println(F("================================="));
}

void loop() {
  // Nothing
}
