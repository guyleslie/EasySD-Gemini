#ifndef _DEBUGLOG_H
#define _DEBUGLOG_H

/**
 * EasySD IRQHack64 - Unified Debug Logging API
 *
 * @deprecated Replaced by EasySDLog.h (Sprint 12, 2026-03-03).
 *   EasySDLog.h provides 7 categories, 5 levels, selective compile,
 *   and 72% fewer log statements. Use EasySDLog.h for new code.
 *
 * Version: 1.0
 * Date: 2025-12-26
 *
 * Purpose:
 *   Provides a centralized, conditional logging system for debug builds.
 *   In release builds (EASYSD_DEBUG_SERIAL not defined), all logging
 *   compiles to zero overhead.
 *
 * Usage:
 *   #include "DebugLog.h"
 *
 *   DBG_BEGIN(57600);                    // setup()
 *   DBG_INFO("System initialized");      // Constant strings
 *   DBG_WARN("Low memory");
 *   DBG_ERR("SD card failed");
 *
 *   DBG_PRINT(freeRAM);                  // Variable output
 *   DBG_PRINTLN_F(" bytes free");
 *
 * Log Levels:
 *   [INFO]  - Normal operation messages
 *   [WARN]  - Warnings, non-critical issues
 *   [ERR ]  - Errors, failures
 *   [TRACE] - Detailed debug traces (verbose)
 *   [RAW]   - Raw print/println (no prefix)
 */

#ifdef EASYSD_DEBUG_SERIAL

  // Serial initialization
  #define DBG_BEGIN(baud)    Serial.begin(baud)

  // Leveled logging (constant strings only - use F() macro internally)
  #define DBG_INFO(msg)      Serial.println(F("[INFO] " msg))
  #define DBG_WARN(msg)      Serial.println(F("[WARN] " msg))
  #define DBG_ERR(msg)       Serial.println(F("[ERR ] " msg))
  #define DBG_TRACE(msg)     Serial.println(F("[TRACE] " msg))

  // Raw print/println (for variables and formatted output)
  #define DBG_PRINT(x)       Serial.print(x)
  #define DBG_PRINTLN(x)     Serial.println(x)
  #define DBG_PRINT_F(msg)   Serial.print(F(msg))
  #define DBG_PRINTLN_F(msg) Serial.println(F(msg))

  // Utility macros
  #define DBG_HEX(x)         Serial.print(x, HEX)
  #define DBG_DEC(x)         Serial.print(x, DEC)
  #define DBG_NEWLINE()      Serial.println()

  // Structured logging helpers
  #define DBG_HEADER(title) \
    do { \
      Serial.println(F("====================================")); \
      Serial.print(F("== ")); Serial.print(F(title)); Serial.println(F(" ==")); \
      Serial.println(F("====================================")); \
    } while(0)

  #define DBG_SEPARATOR() \
    Serial.println(F("------------------------------------"))

  // Key-value pair logging
  #define DBG_KV(key, value) \
    do { \
      Serial.print(F("  ")); \
      Serial.print(F(key)); \
      Serial.print(F(": ")); \
      Serial.println(value); \
    } while(0)

  #define DBG_KV_F(key, value) \
    do { \
      Serial.print(F("  ")); \
      Serial.print(F(key)); \
      Serial.print(F(": ")); \
      Serial.println(F(value)); \
    } while(0)

#else

  // Release build - all logging compiles to nothing (zero overhead)
  #define DBG_BEGIN(baud)        ((void)0)
  #define DBG_INFO(msg)          ((void)0)
  #define DBG_WARN(msg)          ((void)0)
  #define DBG_ERR(msg)           ((void)0)
  #define DBG_TRACE(msg)         ((void)0)
  #define DBG_PRINT(x)           ((void)0)
  #define DBG_PRINTLN(x)         ((void)0)
  #define DBG_PRINT_F(msg)       ((void)0)
  #define DBG_PRINTLN_F(msg)     ((void)0)
  #define DBG_HEX(x)             ((void)0)
  #define DBG_DEC(x)             ((void)0)
  #define DBG_NEWLINE()          ((void)0)
  #define DBG_HEADER(title)      ((void)0)
  #define DBG_SEPARATOR()        ((void)0)
  #define DBG_KV(key, value)     ((void)0)
  #define DBG_KV_F(key, value)   ((void)0)

#endif // EASYSD_DEBUG_SERIAL

/**
 * Deprecated Legacy Macros (for migration reference)
 *
 * Before (old style):
 *   #ifdef EASYSD_DEBUG_SERIAL
 *   Serial.println(F("SD init OK"));
 *   Serial.print(F("Free RAM: ")); Serial.println(freeRAM);
 *   #endif
 *
 * After (new style):
 *   DBG_INFO("SD init OK");
 *   DBG_PRINT_F("Free RAM: "); DBG_PRINTLN(freeRAM);
 *
 * Benefits:
 *   - Consistent log format with level prefixes
 *   - Cleaner code (no #ifdef clutter)
 *   - Easy to grep logs by level: grep "\[ERR \]" log.txt
 *   - Zero overhead in release builds (compiler optimizes out)
 */

#endif // _DEBUGLOG_H
