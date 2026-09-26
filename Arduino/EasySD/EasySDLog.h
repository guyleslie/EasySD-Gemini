#ifndef _EASYSDLOG_H
#define _EASYSDLOG_H

/**
 * @file EasySDLog.h
 * @brief Logging for EasySD Arduino firmware
 *
 * Two levels only: LOGI (state transitions) and LOGE (errors).
 * Zero overhead in release builds (compile-time gating via EASYSD_DEBUG_SERIAL).
 * Message strings live in PROGMEM - no RAM cost.
 *
 * USAGE:
 *   LOG_BEGIN(57600);                   // in setup()
 *   LOGI(SD, "Card OK");                // [INFO][SD] Card OK
 *   LOGE(DIR, "chdir failed");          // [ERR ][DIR] chdir failed
 *   LOG_PRINT_F("RAM: "); LOG_PRINTLN(FreeStack());
 *
 * CATEGORIES: SYS, SD, DIR, FILE, PROTO, PRG, ERR
 * Override LOG_ENABLE_* before including this header to select categories.
 *
 * FLASH BUDGET NOTES (ATmega328P, 30.7 KB):
 *   - The "[LEVEL][CAT] " tag is emitted from one shared PROGMEM table
 *     (easysdLogLine) instead of being baked into every message literal, where
 *     it would cost 12 flash bytes per call site.
 *   - Output goes through a polled TX-only UART writer, not HardwareSerial.
 *     The silent release build does not link HardwareSerial at all, so using it
 *     here charges the debug build for the full Print vtable, both USART ISRs,
 *     the ring buffers and the Serial object (~600 B flash, ~65 B RAM).
 *     Polled TX also cannot perturb the IO2 pulse decoder: no UART interrupt
 *     ever fires.
 */

//==============================================================================
// SHARED PRIMITIVES (any build that logs at all)
//==============================================================================

#if defined(EASYSD_DEBUG_SERIAL) || defined(EASYSD_RELEASE_LOG)

  #include <stdint.h>
  #include <avr/pgmspace.h>

  // Category ids - index order must match kCats[] in EasySDLog.cpp.
  #define LOGCAT_SYS   0
  #define LOGCAT_SD    1
  #define LOGCAT_DIR   2
  #define LOGCAT_FILE  3
  #define LOGCAT_PRG   4
  #define LOGCAT_PROTO 5
  #define LOGCAT_ERR   6
  #define LOGLVL_ERR   0x80

  void easysdLogBegin(uint32_t baud);
  void easysdLogPutc(char c);
  void easysdLogPuts(const char* s);
  void easysdLogPuts_P(const char* sP);
  void easysdLogNewline(void);
  void easysdLogFlush(void);
  void easysdLogU32(uint32_t v);
  void easysdLogS32(int32_t v);
  void easysdLogHex(uint32_t v);
  void easysdLogLine(uint8_t tag, const char* msgP);

  // Value printing: one overload set so call sites keep passing plain values.
  static inline void easysdLogVal(const char* s)   { easysdLogPuts(s); }
  static inline void easysdLogVal(char* s)         { easysdLogPuts(s); }
  static inline void easysdLogVal(char c)          { easysdLogPutc(c); }
  static inline void easysdLogVal(bool v)          { easysdLogPutc(v ? 0x31 : 0x30); }
  static inline void easysdLogVal(unsigned char v) { easysdLogU32(v); }
  static inline void easysdLogVal(signed char v)   { easysdLogS32(v); }
  static inline void easysdLogVal(unsigned int v)  { easysdLogU32(v); }
  static inline void easysdLogVal(int v)           { easysdLogS32(v); }
  static inline void easysdLogVal(unsigned long v) { easysdLogU32(v); }
  static inline void easysdLogVal(long v)          { easysdLogS32(v); }

  #define LOG_BEGIN(baud) easysdLogBegin(baud)
  // Bounded drain: waits only until the last byte left the data register.
  #define LOG_FLUSH()     easysdLogFlush()

#else

  #define LOG_BEGIN(baud) ((void)0)
  #define LOG_FLUSH()     ((void)0)

#endif

#ifdef EASYSD_DEBUG_SERIAL

  //============================================================================
  // CATEGORY ENABLE FLAGS
  // Set to 0 to save flash when debugging a specific subsystem.
  //============================================================================
  #ifndef LOG_ENABLE_SYS
    #define LOG_ENABLE_SYS    1
  #endif
  #ifndef LOG_ENABLE_SD
    #define LOG_ENABLE_SD     1
  #endif
  #ifndef LOG_ENABLE_DIR
    #define LOG_ENABLE_DIR    1
  #endif
  #ifndef LOG_ENABLE_FILE
    #define LOG_ENABLE_FILE   1
  #endif
  #ifndef LOG_ENABLE_PRG
    #define LOG_ENABLE_PRG    0  // default OFF — saves ~500B flash
  #endif
  #ifndef LOG_ENABLE_PROTO
    #define LOG_ENABLE_PROTO  0  // default OFF — saves ~800B flash
  #endif
  #ifndef LOG_ENABLE_LOAD
    #define LOG_ENABLE_LOAD   0  // concise user-facing load activity log
  #endif
  #ifndef LOG_ENABLE_ERR
    #define LOG_ENABLE_ERR    1
  #endif
  #ifndef LOG_ENABLE_RAW
    #define LOG_ENABLE_RAW    0  // raw variable prints bypass categories; opt in only
  #endif
  #ifndef LOG_ENABLE_NI
    #define LOG_ENABLE_NI     1  // CVD non-interrupted stream diagnostics
  #endif

  //============================================================================
  // ERROR LEVEL (LOGE)
  //============================================================================
  #if LOG_ENABLE_SYS
    #define LOGE_SYS_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_SYS, PSTR(msg))
  #else
    #define LOGE_SYS_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_SD
    #define LOGE_SD_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_SD, PSTR(msg))
  #else
    #define LOGE_SD_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_DIR
    #define LOGE_DIR_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_DIR, PSTR(msg))
  #else
    #define LOGE_DIR_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_FILE
    #define LOGE_FILE_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_FILE, PSTR(msg))
  #else
    #define LOGE_FILE_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_PRG
    #define LOGE_PRG_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_PRG, PSTR(msg))
  #else
    #define LOGE_PRG_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_PROTO
    #define LOGE_PROTO_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_PROTO, PSTR(msg))
  #else
    #define LOGE_PROTO_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_ERR
    #define LOGE_ERR_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_ERR, PSTR(msg))
  #else
    #define LOGE_ERR_IMPL(msg) ((void)0)
  #endif
  #define LOGE(cat, msg) LOGE_##cat##_IMPL(msg)

  //============================================================================
  // INFO LEVEL (LOGI)
  //============================================================================
  #if LOG_ENABLE_SYS
    #define LOGI_SYS_IMPL(msg) easysdLogLine(LOGCAT_SYS, PSTR(msg))
  #else
    #define LOGI_SYS_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_SD
    #define LOGI_SD_IMPL(msg) easysdLogLine(LOGCAT_SD, PSTR(msg))
  #else
    #define LOGI_SD_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_DIR
    #define LOGI_DIR_IMPL(msg) easysdLogLine(LOGCAT_DIR, PSTR(msg))
  #else
    #define LOGI_DIR_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_FILE
    #define LOGI_FILE_IMPL(msg) easysdLogLine(LOGCAT_FILE, PSTR(msg))
  #else
    #define LOGI_FILE_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_PRG
    #define LOGI_PRG_IMPL(msg) easysdLogLine(LOGCAT_PRG, PSTR(msg))
  #else
    #define LOGI_PRG_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_PROTO
    #define LOGI_PROTO_IMPL(msg) easysdLogLine(LOGCAT_PROTO, PSTR(msg))
  #else
    #define LOGI_PROTO_IMPL(msg) ((void)0)
  #endif
  #if LOG_ENABLE_ERR
    #define LOGI_ERR_IMPL(msg) easysdLogLine(LOGCAT_ERR, PSTR(msg))
  #else
    #define LOGI_ERR_IMPL(msg) ((void)0)
  #endif
  #define LOGI(cat, msg) LOGI_##cat##_IMPL(msg)

  //============================================================================
  // Concise load activity log
  //============================================================================
  #if LOG_ENABLE_LOAD
    #define LOG_LOAD_TXT_(msg) easysdLogPuts_P(PSTR(msg))
    #define LOG_LOAD_MENU() do { LOG_LOAD_TXT_("[LOAD] EasySD menu"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_LAUNCH(name, size) do { \
      LOG_LOAD_TXT_("[LOAD] launch "); easysdLogVal(name); \
      LOG_LOAD_TXT_(" size="); easysdLogVal(size); easysdLogNewline(); \
    } while(0)
    #define LOG_LOAD_PATH(path) do { LOG_LOAD_TXT_("[LOAD] path "); easysdLogVal(path); easysdLogNewline(); } while(0)
    #define LOG_LOAD_OPEN(name) do { LOG_LOAD_TXT_("[LOAD] open "); easysdLogVal(name); easysdLogNewline(); } while(0)
    #define LOG_LOAD_OPEN_OK() do { LOG_LOAD_TXT_("[LOAD] open ok"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_OPEN_FAIL() do { LOG_LOAD_TXT_("[ERR ][LOAD] open fail"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_INFO_SIZE(size) do { LOG_LOAD_TXT_("[LOAD] size"); easysdLogVal(size); easysdLogNewline(); } while(0)
    #define LOG_LOAD_CLOSE() do { LOG_LOAD_TXT_("[LOAD] close"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_DONE() do { LOG_LOAD_TXT_("[LOAD] done"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_READ_BEGIN(pages) do { LOG_LOAD_TXT_("[LOAD] read p="); easysdLogVal(pages); easysdLogNewline(); } while(0)
    #define LOG_LOAD_READ_RESULT_(status, pages, bytes, pad) do { \
      LOG_LOAD_TXT_("[LOAD] read " status " p="); easysdLogVal(pages); \
      LOG_LOAD_TXT_(" b="); easysdLogVal(bytes); \
      LOG_LOAD_TXT_(" pad="); easysdLogVal(pad); easysdLogNewline(); \
    } while(0)
    #define LOG_LOAD_READ_OK(pages, bytes, pad) LOG_LOAD_READ_RESULT_("ok", pages, bytes, pad)
    #define LOG_LOAD_READ_EOF(pages, bytes, pad) LOG_LOAD_READ_RESULT_("eof", pages, bytes, pad)
    #define LOG_LOAD_READ_STALL(pages, bytes, pad) LOG_LOAD_READ_RESULT_("stall", pages, bytes, pad)
    #define LOG_LOAD_READ_NO_FILE() do { LOG_LOAD_TXT_("[ERR ][LOAD] read no file"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_INFO_NO_FILE() do { LOG_LOAD_TXT_("[ERR ][LOAD] info no file"); easysdLogNewline(); } while(0)
    #define LOG_LOAD_SD_FAIL() do { LOG_LOAD_TXT_("[ERR ][LOAD] sd fail"); easysdLogNewline(); } while(0)
  #else
    #define LOG_LOAD_MENU() ((void)0)
    #define LOG_LOAD_LAUNCH(name, size) ((void)0)
    #define LOG_LOAD_PATH(path) ((void)0)
    #define LOG_LOAD_OPEN(name) ((void)0)
    #define LOG_LOAD_OPEN_OK() ((void)0)
    #define LOG_LOAD_OPEN_FAIL() ((void)0)
    #define LOG_LOAD_INFO_SIZE(size) ((void)0)
    #define LOG_LOAD_CLOSE() ((void)0)
    #define LOG_LOAD_DONE() ((void)0)
    #define LOG_LOAD_READ_BEGIN(pages) ((void)0)
    #define LOG_LOAD_READ_RESULT_(status, pages, bytes, pad) ((void)0)
    #define LOG_LOAD_READ_OK(pages, bytes, pad) ((void)0)
    #define LOG_LOAD_READ_EOF(pages, bytes, pad) ((void)0)
    #define LOG_LOAD_READ_STALL(pages, bytes, pad) ((void)0)
    #define LOG_LOAD_READ_NO_FILE() ((void)0)
    #define LOG_LOAD_INFO_NO_FILE() ((void)0)
    #define LOG_LOAD_SD_FAIL() ((void)0)
  #endif

  //============================================================================
  // CVD / non-interrupted stream diagnostics
  //============================================================================
  #if LOG_ENABLE_NI
    #define LOG_NI_START() do { easysdLogPuts_P(PSTR("[NI  ] start")); easysdLogNewline(); } while(0)
    #define LOG_NI_BLOCK_SIZE(bytes) do { easysdLogPuts_P(PSTR("[NI  ] block=")); easysdLogVal(bytes); easysdLogNewline(); } while(0)
    #define LOG_NI_FIRST_TIMEOUT() do { easysdLogPuts_P(PSTR("[NI  ] first-byte timeout")); easysdLogNewline(); } while(0)
    #define LOG_NI_EXIT(reason) do { easysdLogPuts_P(PSTR("[NI  ] exit " reason)); easysdLogNewline(); } while(0)
  #else
    #define LOG_NI_START() ((void)0)
    #define LOG_NI_BLOCK_SIZE(bytes) ((void)0)
    #define LOG_NI_FIRST_TIMEOUT() ((void)0)
    #define LOG_NI_EXIT(reason) ((void)0)
  #endif

  //============================================================================
  // VARIABLE OUTPUT MACROS
  //============================================================================
  #if LOG_ENABLE_RAW
    #define LOG_PRINT(x)        easysdLogVal(x)
    #define LOG_PRINTLN(x)      do { easysdLogVal(x); easysdLogNewline(); } while(0)
    #define LOG_PRINT_F(msg)    easysdLogPuts_P(PSTR(msg))
    #define LOG_PRINTLN_F(msg)  do { easysdLogPuts_P(PSTR(msg)); easysdLogNewline(); } while(0)
    #define LOG_HEX(x)          easysdLogHex(x)
    #define LOG_DEC(x)          easysdLogVal(x)
    #define LOG_NEWLINE()       easysdLogNewline()
  #else
    #define LOG_PRINT(x)        ((void)0)
    #define LOG_PRINTLN(x)      ((void)0)
    #define LOG_PRINT_F(msg)    ((void)0)
    #define LOG_PRINTLN_F(msg)  ((void)0)
    #define LOG_HEX(x)          ((void)0)
    #define LOG_DEC(x)          ((void)0)
    #define LOG_NEWLINE()       ((void)0)
  #endif

#elif defined(EASYSD_RELEASE_LOG)
  //----------------------------------------------------------------------------
  // RELEASE LOG BUILD — lightweight serial for field diagnosis
  // Only DIR, SYS, SD, ERR categories active. ~1-2KB flash cost.
  //----------------------------------------------------------------------------

  // Release-log category selection (DIR/SYS/SD/ERR only)

  #define LOGE_SYS_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_SYS, PSTR(msg))
  #define LOGE_SD_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_SD, PSTR(msg))
  #define LOGE_DIR_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_DIR, PSTR(msg))
  #define LOGE_FILE_IMPL(msg) ((void)0)
  #define LOGE_PRG_IMPL(msg) ((void)0)
  #define LOGE_PROTO_IMPL(msg) ((void)0)
  #define LOGE_ERR_IMPL(msg) easysdLogLine(LOGLVL_ERR | LOGCAT_ERR, PSTR(msg))
  #define LOGE(cat, msg)       LOGE_##cat##_IMPL(msg)

  #define LOGI_SYS_IMPL(msg) easysdLogLine(LOGCAT_SYS, PSTR(msg))
  #define LOGI_SD_IMPL(msg) easysdLogLine(LOGCAT_SD, PSTR(msg))
  #define LOGI_DIR_IMPL(msg) easysdLogLine(LOGCAT_DIR, PSTR(msg))
  #define LOGI_FILE_IMPL(msg) ((void)0)
  #define LOGI_PRG_IMPL(msg) ((void)0)
  #define LOGI_PROTO_IMPL(msg) ((void)0)
  #define LOGI_ERR_IMPL(msg) ((void)0)
  #define LOGI(cat, msg)       LOGI_##cat##_IMPL(msg)


  #define LOG_LOAD_MENU() ((void)0)
  #define LOG_LOAD_LAUNCH(name, size) ((void)0)
  #define LOG_LOAD_PATH(path) ((void)0)
  #define LOG_LOAD_OPEN(name) ((void)0)
  #define LOG_LOAD_OPEN_OK() ((void)0)
  #define LOG_LOAD_OPEN_FAIL() ((void)0)
  #define LOG_LOAD_INFO_SIZE(size) ((void)0)
  #define LOG_LOAD_CLOSE() ((void)0)
  #define LOG_LOAD_DONE() ((void)0)
  #define LOG_LOAD_READ_BEGIN(pages) ((void)0)
  #define LOG_LOAD_READ_RESULT_(status, pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_OK(pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_EOF(pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_STALL(pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_NO_FILE() ((void)0)
  #define LOG_LOAD_INFO_NO_FILE() ((void)0)
  #define LOG_LOAD_SD_FAIL() ((void)0)
  #define LOG_NI_START() ((void)0)
  #define LOG_NI_BLOCK_SIZE(bytes) ((void)0)
  #define LOG_NI_FIRST_TIMEOUT() ((void)0)
  #define LOG_NI_EXIT(reason) ((void)0)

  #define LOG_PRINT(x)         ((void)0)
  #define LOG_PRINTLN(x)       ((void)0)
  #define LOG_PRINT_F(msg)     ((void)0)
  #define LOG_PRINTLN_F(msg)   ((void)0)
  #define LOG_HEX(x)           ((void)0)
  #define LOG_DEC(x)           ((void)0)
  #define LOG_NEWLINE()        ((void)0)

#else
  //----------------------------------------------------------------------------
  // RELEASE BUILD (silent) — zero overhead
  //----------------------------------------------------------------------------
  #define LOGE(cat, msg)        ((void)0)
  #define LOGI(cat, msg)        ((void)0)
  #define LOG_LOAD_MENU()       ((void)0)
  #define LOG_LOAD_LAUNCH(name, size) ((void)0)
  #define LOG_LOAD_PATH(path)   ((void)0)
  #define LOG_LOAD_OPEN(name)   ((void)0)
  #define LOG_LOAD_OPEN_OK()    ((void)0)
  #define LOG_LOAD_OPEN_FAIL()  ((void)0)
  #define LOG_LOAD_INFO_SIZE(size) ((void)0)
  #define LOG_LOAD_CLOSE()      ((void)0)
  #define LOG_LOAD_DONE()       ((void)0)
  #define LOG_LOAD_READ_BEGIN(pages) ((void)0)
  #define LOG_LOAD_READ_RESULT_(status, pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_OK(pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_EOF(pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_STALL(pages, bytes, pad) ((void)0)
  #define LOG_LOAD_READ_NO_FILE() ((void)0)
  #define LOG_LOAD_INFO_NO_FILE() ((void)0)
  #define LOG_LOAD_SD_FAIL()    ((void)0)
  #define LOG_NI_START()        ((void)0)
  #define LOG_NI_BLOCK_SIZE(bytes) ((void)0)
  #define LOG_NI_FIRST_TIMEOUT() ((void)0)
  #define LOG_NI_EXIT(reason)   ((void)0)
  #define LOG_PRINT(x)          ((void)0)
  #define LOG_PRINTLN(x)        ((void)0)
  #define LOG_PRINT_F(msg)      ((void)0)
  #define LOG_PRINTLN_F(msg)    ((void)0)
  #define LOG_HEX(x)            ((void)0)
  #define LOG_DEC(x)            ((void)0)
  #define LOG_NEWLINE()         ((void)0)

#endif // EASYSD_DEBUG_SERIAL

#endif // _EASYSDLOG_H
