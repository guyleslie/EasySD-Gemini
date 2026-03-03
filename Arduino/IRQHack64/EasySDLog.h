#ifndef _EASYSDLOG_H
#define _EASYSDLOG_H

/**
 * @file EasySDLog.h
 * @brief Professional Logging System for EasySD IRQHack64 v2.0
 * @date 2026-01-02
 *
 * CRITICAL ISR SAFETY POLICY:
 *   NEVER call ANY LOG macro from interrupt service routines (ISR).
 *   Use volatile counters in ISR, translate to logs in main loop.
 *   See LOGGING_SYSTEM_DESIGN.md section 5 for ISR-safe pattern.
 *
 * FEATURES:
 *   - Categorized logging (SYS, SD, DIR, FILE, PROTO, PRG, ERR)
 *   - Leveled output (ERROR, WARN, INFO, DEBUG, TRACE)
 *   - Selective category compilation (LOG_ENABLE_* flags)
 *   - Zero overhead in release builds (compile-time gating)
 *   - PROGMEM string storage (minimal RAM usage)
 *   - Simple, clean API with no legacy baggage
 *
 * COMPILE FLAGS:
 *   -DEASYSD_DEBUG_SERIAL           Enable logging framework
 *   LOG_ENABLE_SYS=1                Enable SYS category (~960 bytes)
 *   LOG_ENABLE_SD=1                 Enable SD category (~180 bytes)
 *   LOG_ENABLE_DIR=1                Enable DIR category (~1800 bytes)
 *   LOG_ENABLE_FILE=1               Enable FILE category (~1600 bytes)
 *   LOG_ENABLE_PRG=0                Disable PRG (default OFF — saves ~200B flash)
 *   LOG_ENABLE_PROTO=0              Disable PROTO (default OFF — saves ~180B flash)
 *   LOG_ENABLE_ERR=1                Enable ERR category (~80 bytes)
 *   (no flags)                      Disable all logging (release builds)
 *
 * FLASH USAGE (Arduino Nano, 2026-03-03):
 *   Release build (no logging):     22714 bytes (73%) — 8006 bytes free
 *   Debug build (SYS+SD+DIR+FILE+ERR): 30248 bytes (98%) — 472 bytes free
 *   See LOGGING_SELECTIVE_CATEGORIES.md for optimization guide
 *
 * USAGE:
 *   LOG_BEGIN(57600);                  // setup()
 *   LOGI(SYS, "System initialized");   // Categorized message
 *   LOG_PRINT_F("RAM: ");              // Variable output
 *   LOG_PRINTLN(FreeStack());
 *
 * OUTPUT FORMAT:
 *   [LEVEL][CATEGORY] message
 *   Example: [INFO][SD] Card initialized
 *
 * DOCUMENTATION:
 *   LOGGING_SYSTEM_DESIGN.md          - Complete API specification
 *   LOGGING_SELECTIVE_CATEGORIES.md   - Flash optimization guide
 *   LOGGING_MIGRATION_COMPLETE.md     - Implementation history
 */

//==============================================================================
// COMPILE-TIME CONFIGURATION
//==============================================================================

#ifdef EASYSD_DEBUG_SERIAL
  //----------------------------------------------------------------------------
  // DEBUG BUILD - Selective category logging
  //----------------------------------------------------------------------------

  //============================================================================
  // CATEGORY ENABLE FLAGS
  //============================================================================
  // Override these flags to selectively enable/disable categories
  // Reduces flash usage when debugging specific subsystems
  //
  // Flash usage estimates (approximate):
  //   LOG_ENABLE_SYS    ~960 bytes  (system, memory, status)
  //   LOG_ENABLE_SD     ~180 bytes  (SD card initialization)
  //   LOG_ENABLE_DIR    ~1800 bytes (directory navigation)
  //   LOG_ENABLE_FILE   ~1600 bytes (file operations)
  //   LOG_ENABLE_PRG    ~1200 bytes (program loading)
  //   LOG_ENABLE_PROTO  ~800 bytes  (protocol/streaming)
  //   LOG_ENABLE_ERR    ~80 bytes   (errors only)
  //
  // USAGE EXAMPLES:
  //   All categories (default): all flags = 1 (may not fit on Nano)
  //   Debug directory only:     DIR=1, others=0
  //   Debug file + dir:         DIR=1, FILE=1, others=0
  //   Errors only (minimal):    ERR=1, others=0
  //
  // To customize, #define these BEFORE including EasySDLog.h in your sketch:
  //   #define LOG_ENABLE_DIR 1
  //   #define LOG_ENABLE_FILE 1
  //   #define LOG_ENABLE_PROTO 0  // Disable protocol logs
  //   #include "EasySDLog.h"

  #ifndef LOG_ENABLE_SYS
    #define LOG_ENABLE_SYS    1  // System (init, memory, status)
  #endif
  #ifndef LOG_ENABLE_SD
    #define LOG_ENABLE_SD     1  // SD card operations
  #endif
  #ifndef LOG_ENABLE_DIR
    #define LOG_ENABLE_DIR    1  // Directory navigation
  #endif
  #ifndef LOG_ENABLE_FILE
    #define LOG_ENABLE_FILE   1  // File operations
  #endif
  #ifndef LOG_ENABLE_PRG
    #define LOG_ENABLE_PRG    0  // Program loading (default OFF — saves ~500B flash)
  #endif
  #ifndef LOG_ENABLE_PROTO
    #define LOG_ENABLE_PROTO  0  // Protocol/streaming (default OFF — saves ~800B flash)
  #endif
  #ifndef LOG_ENABLE_ERR
    #define LOG_ENABLE_ERR    1  // Critical errors (always recommended)
  #endif

  //============================================================================
  // INITIALIZATION
  //============================================================================

  /**
   * @brief Initialize Serial interface for logging
   * @param baud Baud rate (typically 57600)
   * @usage Call once in setup()
   */
  #define LOG_BEGIN(baud) Serial.begin(baud)

  //============================================================================
  // CATEGORIZED LOGGING MACROS (SELECTIVE COMPILATION)
  //============================================================================
  // Each category can be independently enabled/disabled at compile time
  // using LOG_ENABLE_* flags defined above

  //----------------------------------------------------------------------------
  // ERROR LEVEL (LOGE) - Category-specific implementations
  // Single-call: F("[ERR ][CAT] " msg) concatenates at compile time
  //----------------------------------------------------------------------------
  #if LOG_ENABLE_SYS
    #define LOGE_SYS_IMPL(msg) Serial.println(F("[ERR ][SYS] " msg))
  #else
    #define LOGE_SYS_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_SD
    #define LOGE_SD_IMPL(msg) Serial.println(F("[ERR ][SD] " msg))
  #else
    #define LOGE_SD_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_DIR
    #define LOGE_DIR_IMPL(msg) Serial.println(F("[ERR ][DIR] " msg))
  #else
    #define LOGE_DIR_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_FILE
    #define LOGE_FILE_IMPL(msg) Serial.println(F("[ERR ][FILE] " msg))
  #else
    #define LOGE_FILE_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PRG
    #define LOGE_PRG_IMPL(msg) Serial.println(F("[ERR ][PRG] " msg))
  #else
    #define LOGE_PRG_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PROTO
    #define LOGE_PROTO_IMPL(msg) Serial.println(F("[ERR ][PROTO] " msg))
  #else
    #define LOGE_PROTO_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_ERR
    #define LOGE_ERR_IMPL(msg) Serial.println(F("[ERR ][ERR] " msg))
  #else
    #define LOGE_ERR_IMPL(msg) ((void)0)
  #endif

  /**
   * @brief Log error message with category (selective compilation)
   * @param cat Category: SYS, SD, DIR, FILE, PROTO, PRG, ERR
   * @param msg String literal (auto-wrapped in F() macro)
   * @usage LOGE(SD, "Card init failed");
   * @output [ERR ][SD] Card init failed
   * @note Only compiles code if LOG_ENABLE_<cat> is enabled
   */
  #define LOGE(cat, msg) LOGE_##cat##_IMPL(msg)

  //----------------------------------------------------------------------------
  // WARNING LEVEL (LOGW) - Category-specific implementations
  //----------------------------------------------------------------------------
  #if LOG_ENABLE_SYS
    #define LOGW_SYS_IMPL(msg) Serial.println(F("[WARN][SYS] " msg))
  #else
    #define LOGW_SYS_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_SD
    #define LOGW_SD_IMPL(msg) Serial.println(F("[WARN][SD] " msg))
  #else
    #define LOGW_SD_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_DIR
    #define LOGW_DIR_IMPL(msg) Serial.println(F("[WARN][DIR] " msg))
  #else
    #define LOGW_DIR_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_FILE
    #define LOGW_FILE_IMPL(msg) Serial.println(F("[WARN][FILE] " msg))
  #else
    #define LOGW_FILE_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PRG
    #define LOGW_PRG_IMPL(msg) Serial.println(F("[WARN][PRG] " msg))
  #else
    #define LOGW_PRG_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PROTO
    #define LOGW_PROTO_IMPL(msg) Serial.println(F("[WARN][PROTO] " msg))
  #else
    #define LOGW_PROTO_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_ERR
    #define LOGW_ERR_IMPL(msg) Serial.println(F("[WARN][ERR] " msg))
  #else
    #define LOGW_ERR_IMPL(msg) ((void)0)
  #endif

  /**
   * @brief Log warning message with category (selective compilation)
   * @param cat Category: SYS, SD, DIR, FILE, PROTO, PRG, ERR
   * @param msg String literal
   * @usage LOGW(DIR, "Directory empty");
   * @output [WARN][DIR] Directory empty
   * @note Only compiles code if LOG_ENABLE_<cat> is enabled
   */
  #define LOGW(cat, msg) LOGW_##cat##_IMPL(msg)

  //----------------------------------------------------------------------------
  // INFO LEVEL (LOGI) - Category-specific implementations
  //----------------------------------------------------------------------------
  #if LOG_ENABLE_SYS
    #define LOGI_SYS_IMPL(msg) Serial.println(F("[INFO][SYS] " msg))
  #else
    #define LOGI_SYS_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_SD
    #define LOGI_SD_IMPL(msg) Serial.println(F("[INFO][SD] " msg))
  #else
    #define LOGI_SD_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_DIR
    #define LOGI_DIR_IMPL(msg) Serial.println(F("[INFO][DIR] " msg))
  #else
    #define LOGI_DIR_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_FILE
    #define LOGI_FILE_IMPL(msg) Serial.println(F("[INFO][FILE] " msg))
  #else
    #define LOGI_FILE_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PRG
    #define LOGI_PRG_IMPL(msg) Serial.println(F("[INFO][PRG] " msg))
  #else
    #define LOGI_PRG_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PROTO
    #define LOGI_PROTO_IMPL(msg) Serial.println(F("[INFO][PROTO] " msg))
  #else
    #define LOGI_PROTO_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_ERR
    #define LOGI_ERR_IMPL(msg) Serial.println(F("[INFO][ERR] " msg))
  #else
    #define LOGI_ERR_IMPL(msg) ((void)0)
  #endif

  /**
   * @brief Log info message with category (selective compilation)
   * @param cat Category: SYS, SD, DIR, FILE, PROTO, PRG, ERR
   * @param msg String literal
   * @usage LOGI(SYS, "System ready");
   * @output [INFO][SYS] System ready
   * @note Only compiles code if LOG_ENABLE_<cat> is enabled
   */
  #define LOGI(cat, msg) LOGI_##cat##_IMPL(msg)

  //----------------------------------------------------------------------------
  // DEBUG LEVEL (LOGD) - Category-specific implementations
  //----------------------------------------------------------------------------
  #if LOG_ENABLE_SYS
    #define LOGD_SYS_IMPL(msg) Serial.println(F("[DBG ][SYS] " msg))
  #else
    #define LOGD_SYS_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_SD
    #define LOGD_SD_IMPL(msg) Serial.println(F("[DBG ][SD] " msg))
  #else
    #define LOGD_SD_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_DIR
    #define LOGD_DIR_IMPL(msg) Serial.println(F("[DBG ][DIR] " msg))
  #else
    #define LOGD_DIR_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_FILE
    #define LOGD_FILE_IMPL(msg) Serial.println(F("[DBG ][FILE] " msg))
  #else
    #define LOGD_FILE_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PRG
    #define LOGD_PRG_IMPL(msg) Serial.println(F("[DBG ][PRG] " msg))
  #else
    #define LOGD_PRG_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PROTO
    #define LOGD_PROTO_IMPL(msg) Serial.println(F("[DBG ][PROTO] " msg))
  #else
    #define LOGD_PROTO_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_ERR
    #define LOGD_ERR_IMPL(msg) Serial.println(F("[DBG ][ERR] " msg))
  #else
    #define LOGD_ERR_IMPL(msg) ((void)0)
  #endif

  /**
   * @brief Log debug message with category (selective compilation)
   * @param cat Category: SYS, SD, DIR, FILE, PROTO, PRG, ERR
   * @param msg String literal
   * @usage LOGD(FILE, "Opening file");
   * @output [DBG ][FILE] Opening file
   * @note Only compiles code if LOG_ENABLE_<cat> is enabled
   */
  #define LOGD(cat, msg) LOGD_##cat##_IMPL(msg)

  //----------------------------------------------------------------------------
  // TRACE LEVEL (LOGT) - Category-specific implementations
  //----------------------------------------------------------------------------
  #if LOG_ENABLE_SYS
    #define LOGT_SYS_IMPL(msg) Serial.println(F("[TRC ][SYS] " msg))
  #else
    #define LOGT_SYS_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_SD
    #define LOGT_SD_IMPL(msg) Serial.println(F("[TRC ][SD] " msg))
  #else
    #define LOGT_SD_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_DIR
    #define LOGT_DIR_IMPL(msg) Serial.println(F("[TRC ][DIR] " msg))
  #else
    #define LOGT_DIR_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_FILE
    #define LOGT_FILE_IMPL(msg) Serial.println(F("[TRC ][FILE] " msg))
  #else
    #define LOGT_FILE_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PRG
    #define LOGT_PRG_IMPL(msg) Serial.println(F("[TRC ][PRG] " msg))
  #else
    #define LOGT_PRG_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_PROTO
    #define LOGT_PROTO_IMPL(msg) Serial.println(F("[TRC ][PROTO] " msg))
  #else
    #define LOGT_PROTO_IMPL(msg) ((void)0)
  #endif

  #if LOG_ENABLE_ERR
    #define LOGT_ERR_IMPL(msg) Serial.println(F("[TRC ][ERR] " msg))
  #else
    #define LOGT_ERR_IMPL(msg) ((void)0)
  #endif

  /**
   * @brief Log trace message with category (very verbose, selective compilation)
   * @param cat Category: SYS, SD, DIR, FILE, PROTO, PRG, ERR
   * @param msg String literal
   * @usage LOGT(PROTO, "Byte transmitted");
   * @output [TRC ][PROTO] Byte transmitted
   * @note Only compiles code if LOG_ENABLE_<cat> is enabled
   */
  #define LOGT(cat, msg) LOGT_##cat##_IMPL(msg)

  //============================================================================
  // VARIABLE OUTPUT MACROS
  //============================================================================

  /**
   * @brief Print variable or expression without newline
   * @param x Variable, expression, or literal
   * @usage LOG_PRINT(fileSize);
   */
  #define LOG_PRINT(x) Serial.print(x)

  /**
   * @brief Print variable or expression with newline
   * @param x Variable, expression, or literal
   * @usage LOG_PRINTLN(freeRAM);
   */
  #define LOG_PRINTLN(x) Serial.println(x)

  /**
   * @brief Print F() string without newline
   * @param msg String literal
   * @usage LOG_PRINT_F("Free RAM: ");
   */
  #define LOG_PRINT_F(msg) Serial.print(F(msg))

  /**
   * @brief Print F() string with newline
   * @param msg String literal
   * @usage LOG_PRINTLN_F("Done");
   */
  #define LOG_PRINTLN_F(msg) Serial.println(F(msg))

  /**
   * @brief Print value as hexadecimal
   * @param x Variable or expression
   * @usage LOG_HEX(byteValue);
   */
  #define LOG_HEX(x) Serial.print(x, HEX)

  /**
   * @brief Print value as decimal
   * @param x Variable or expression
   * @usage LOG_DEC(counter);
   */
  #define LOG_DEC(x) Serial.print(x, DEC)

  /**
   * @brief Print newline only
   * @usage LOG_NEWLINE();
   */
  #define LOG_NEWLINE() Serial.println()

  //============================================================================
  // UTILITY MACROS
  //============================================================================

  /**
   * @brief Print boxed header
   * @param title String literal
   * @usage LOG_HEADER("System Status");
   * @output
   *   ====================================
   *   == System Status ==
   *   ====================================
   */
  #define LOG_HEADER(title) \
    do { \
      Serial.println(F("====================================")); \
      Serial.print(F("== ")); \
      Serial.print(F(title)); \
      Serial.println(F(" ==")); \
      Serial.println(F("====================================")); \
    } while(0)

  /**
   * @brief Print separator line
   * @usage LOG_SEPARATOR();
   * @output ------------------------------------
   */
  #define LOG_SEPARATOR() \
    Serial.println(F("------------------------------------"))

#else
  //----------------------------------------------------------------------------
  // RELEASE BUILD - All logging disabled (zero overhead)
  //----------------------------------------------------------------------------

  #define LOG_BEGIN(baud)       ((void)0)
  #define LOGE(cat, msg)        ((void)0)
  #define LOGW(cat, msg)        ((void)0)
  #define LOGI(cat, msg)        ((void)0)
  #define LOGD(cat, msg)        ((void)0)
  #define LOGT(cat, msg)        ((void)0)
  #define LOG_PRINT(x)          ((void)0)
  #define LOG_PRINTLN(x)        ((void)0)
  #define LOG_PRINT_F(msg)      ((void)0)
  #define LOG_PRINTLN_F(msg)    ((void)0)
  #define LOG_HEX(x)            ((void)0)
  #define LOG_DEC(x)            ((void)0)
  #define LOG_NEWLINE()         ((void)0)
  #define LOG_HEADER(title)     ((void)0)
  #define LOG_SEPARATOR()       ((void)0)

#endif // EASYSD_DEBUG_SERIAL

//==============================================================================
// CATEGORY DEFINITIONS (for documentation only)
//==============================================================================
//
// SYS    - System events (init, reset, mode changes, memory)
// SD     - SD card operations (mount, detect, errors)
// DIR    - Directory navigation (chdir, iteration, path management)
// FILE   - File operations (open, read, write, close, seek)
// PROTO  - Protocol/cartridge interface (transmission, ISR events)
// PRG    - Program loading (.prg, .crt, .tap conversion)
// ERR    - Critical errors (always use LOGE for errors)
//
//==============================================================================

//==============================================================================
// ISR-SAFE DIAGNOSTIC PATTERN (MANDATORY FOR ISR LOGGING)
//==============================================================================
//
// NEVER call LOG macros from ISR. Use this pattern instead:
//
// 1. Declare volatile diagnostic counters (global or class member):
//    volatile uint8_t g_isr_event_count = 0;
//    volatile uint8_t g_isr_error_flags = 0;
//
// 2. In ISR: ONLY increment/set flags (atomic on 8-bit AVR):
//    void SomeISR() {
//      g_isr_event_count++;              // Safe: atomic 8-bit write
//      if (error) g_isr_error_flags |= 0x01;
//      // NO LOG MACROS HERE!
//    }
//
// 3. In main loop: Translate counters to logs:
//    void loop() {
//      static uint8_t last_count = 0;
//      if (g_isr_event_count != last_count) {
//        LOGD(PROTO, "ISR events: ");
//        LOG_PRINTLN(g_isr_event_count);
//        last_count = g_isr_event_count;
//      }
//    }
//
// See LOGGING_SYSTEM_DESIGN.md section 5 for complete examples.
//==============================================================================

#endif // _EASYSDLOG_H
