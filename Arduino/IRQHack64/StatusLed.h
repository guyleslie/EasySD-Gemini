#ifndef STATUS_LED_H
#define STATUS_LED_H

// ============================================================
// STATUS LED (A5 / pin 19) — release builds only.
// In debug mode all functions are empty: serial monitor covers
// status information, so the LED is not needed.
// ============================================================

#ifndef EASYSD_DEBUG_SERIAL

static void __attribute__((noinline))
_ledBlink(uint8_t count, uint8_t on_ms, uint8_t off_ms) {
  for (uint8_t i = 0; i < count; i++) {
    digitalWrite(STATUS_LED, HIGH); delay(on_ms);
    digitalWrite(STATUS_LED, LOW);  delay(off_ms);
  }
}

inline void ledInit()        { pinMode(STATUS_LED, OUTPUT); digitalWrite(STATUS_LED, LOW); }
inline void ledBootOk()      { _ledBlink(3, 200, 150); digitalWrite(STATUS_LED, HIGH); }
inline void ledBootFail()    { _ledBlink(6, 100, 100); }
inline void ledSdRecovered() { _ledBlink(2, 200, 150); digitalWrite(STATUS_LED, HIGH); }
inline void ledSdFail()      { /* LED stays off */ }

#else  // EASYSD_DEBUG_SERIAL — serial monitor handles status reporting

inline void ledInit()        {}
inline void ledBootOk()      {}
inline void ledBootFail()    {}
inline void ledSdRecovered() {}
inline void ledSdFail()      {}

#endif // EASYSD_DEBUG_SERIAL

#endif // STATUS_LED_H
