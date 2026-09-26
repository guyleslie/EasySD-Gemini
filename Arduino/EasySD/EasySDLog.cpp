// Serial log backend: polled TX-only UART plus a shared tag table.
//
// Why not HardwareSerial: the silent release build does not link it at all, so
// every byte of it is a debug-build-only cost -- Print vtable, USART RX/UDRE
// ISRs, both ring buffers and the 47-byte Serial object. A debug build on a
// 30.7 KB ATmega328P cannot afford that. Polled TX also removes the last UART
// interrupt source, so logging can never perturb the IO2 pulse decoder.
//
// Why the shared tag table: every line starts with a 12-byte "[LEVEL][CAT] "
// tag. As part of the message literal the compiler emits a private PROGMEM copy
// per call site (~50 sites); here it is stored once.
//
// Compiled to nothing in silent release builds.

#include "EasySD.h"        // pulls in BuildConfig.h (EASYSD_DEBUG_SERIAL)
#include "EasySDLog.h"

#if defined(EASYSD_DEBUG_SERIAL) || defined(EASYSD_RELEASE_LOG)

#include <avr/io.h>

//------------------------------------------------------------------------------
// Polled TX-only UART
//------------------------------------------------------------------------------

void easysdLogBegin(uint32_t baud) {
  // Double-speed (U2X) divisor, same rounding the Arduino core uses:
  // 57600 on 16 MHz -> UBRR 34, -0.8% error.
  const uint16_t ubrr = (uint16_t)((F_CPU / 4 / baud - 1) / 2);
  UBRR0H = (uint8_t)(ubrr >> 8);
  UBRR0L = (uint8_t)ubrr;
  UCSR0A = (uint8_t)(1 << U2X0);
  UCSR0C = (uint8_t)((1 << UCSZ01) | (1 << UCSZ00));  // 8N1
  UCSR0B = (uint8_t)(1 << TXEN0);                     // TX only, no interrupts
}

void easysdLogPutc(char c) {
  while (!(UCSR0A & (1 << UDRE0))) { }
  UDR0 = (uint8_t)c;
}

void easysdLogPuts(const char* s) {
  while (*s) easysdLogPutc(*s++);
}

void easysdLogPuts_P(const char* sP) {
  char c;
  while ((c = (char)pgm_read_byte(sP++)) != 0) easysdLogPutc(c);
}

void easysdLogNewline(void) {
  easysdLogPutc('\r');
  easysdLogPutc('\n');
}

// Bounded wait: the data register empties within one character time. The shift
// register may still be clocking out the final byte, which costs no CPU and
// raises no interrupt, so it cannot disturb protocol timing.
void easysdLogFlush(void) {
  while (!(UCSR0A & (1 << UDRE0))) { }
}

void easysdLogU32(uint32_t v) {
  char digits[10];
  uint8_t n = 0;
  do {
    digits[n++] = (char)('0' + (uint8_t)(v % 10));
    v /= 10;
  } while (v);
  while (n) easysdLogPutc(digits[--n]);
}

void easysdLogS32(int32_t v) {
  if (v < 0) {
    easysdLogPutc('-');
    easysdLogU32((uint32_t)(-v));
  } else {
    easysdLogU32((uint32_t)v);
  }
}

void easysdLogHex(uint32_t v) {
  char digits[8];
  uint8_t n = 0;
  do {
    const uint8_t nib = (uint8_t)(v & 0x0F);
    digits[n++] = (char)(nib < 10 ? ('0' + nib) : ('A' + nib - 10));
    v >>= 4;
  } while (v);
  while (n) easysdLogPutc(digits[--n]);
}

//------------------------------------------------------------------------------
// Shared tag table
//------------------------------------------------------------------------------

static const char kLvlInfo[] PROGMEM = "[INFO]";
static const char kLvlErr[]  PROGMEM = "[ERR ]";

static const char kCatSys[]   PROGMEM = "[SYS] ";
static const char kCatSd[]    PROGMEM = "[SD] ";
static const char kCatDir[]   PROGMEM = "[DIR] ";
static const char kCatFile[]  PROGMEM = "[FILE] ";
static const char kCatPrg[]   PROGMEM = "[PRG] ";
static const char kCatProto[] PROGMEM = "[PROTO] ";
static const char kCatErr[]   PROGMEM = "[ERR] ";

// Index order must match the LOGCAT_* values in EasySDLog.h.
static const char* const kCats[] PROGMEM = {
  kCatSys, kCatSd, kCatDir, kCatFile, kCatPrg, kCatProto, kCatErr
};

// noinline: LTO would otherwise inline this back into every call site and undo
// the code-size saving the shared table exists for.
void __attribute__((noinline)) easysdLogLine(uint8_t tag, const char* msgP) {
  easysdLogPuts_P((tag & LOGLVL_ERR) ? kLvlErr : kLvlInfo);
  easysdLogPuts_P((const char*)pgm_read_ptr(&kCats[tag & 0x07]));
  easysdLogPuts_P(msgP);
  easysdLogNewline();
}

#endif
