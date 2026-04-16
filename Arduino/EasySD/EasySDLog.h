#ifndef _EASYSDLOG_H
#define _EASYSDLOG_H

/**
 * @file EasySDLog.h
 * @brief Logging for EasySD Arduino firmware
 *
 * Two levels only: LOGI (state transitions) and LOGE (errors).
 * Zero overhead in release builds (compile-time gating via EASYSD_DEBUG_SERIAL).
 * Strings stored in PROGMEM via F() macro — no RAM cost.
 *
 * USAGE:
 *   LOG_BEGIN(57600);                   // in setup()
 *   LOGI(SD, "Card OK");                // [INFO][SD] Card OK
 *   LOGE(DIR, "chdir failed");          // [ERR ][DIR] chdir failed
 *   LOG_PRINT_F("RAM: "); LOG_PRINTLN(FreeStack());
 *
 * CATEGORIES: SYS, SD, DIR, FILE, PROTO, PRG, ERR
 * Override LOG_ENABLE_* before including this header to select categories.
 */

//==============================================================================
// COMPILE-TIME CONFIGURATION
//==============================================================================

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
  #ifndef LOG_ENABLE_ERR
    #define LOG_ENABLE_ERR    1
  #endif

  //============================================================================
  // INITIALIZATION
  //============================================================================
  #define LOG_BEGIN(baud) Serial.begin(baud)

  //============================================================================
  // ERROR LEVEL (LOGE)
  //============================================================================
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
  #define LOGE(cat, msg) LOGE_##cat##_IMPL(msg)

  //============================================================================
  // INFO LEVEL (LOGI)
  //============================================================================
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
  #define LOGI(cat, msg) LOGI_##cat##_IMPL(msg)

  //============================================================================
  // VARIABLE OUTPUT MACROS
  //============================================================================
  #define LOG_PRINT(x)          Serial.print(x)
  #define LOG_PRINTLN(x)        Serial.println(x)
  #define LOG_PRINT_F(msg)      Serial.print(F(msg))
  #define LOG_PRINTLN_F(msg)    Serial.println(F(msg))
  #define LOG_HEX(x)            Serial.print(x, HEX)
  #define LOG_DEC(x)            Serial.print(x, DEC)
  #define LOG_NEWLINE()         Serial.println()

#elif defined(EASYSD_RELEASE_LOG)
  //----------------------------------------------------------------------------
  // RELEASE LOG BUILD — lightweight serial for field diagnosis
  // Only DIR, SYS, SD, ERR categories active. ~1-2KB flash cost.
  //----------------------------------------------------------------------------
  #define LOG_BEGIN(baud)       Serial.begin(baud)

  // Release-log category selection (DIR/SYS/SD/ERR only)
  #define LOGE_SYS_IMPL(msg)   Serial.println(F("[ERR ][SYS] " msg))
  #define LOGE_SD_IMPL(msg)    Serial.println(F("[ERR ][SD] " msg))
  #define LOGE_DIR_IMPL(msg)   Serial.println(F("[ERR ][DIR] " msg))
  #define LOGE_FILE_IMPL(msg)  ((void)0)
  #define LOGE_PRG_IMPL(msg)   ((void)0)
  #define LOGE_PROTO_IMPL(msg) ((void)0)
  #define LOGE_ERR_IMPL(msg)   Serial.println(F("[ERR ][ERR] " msg))
  #define LOGE(cat, msg)       LOGE_##cat##_IMPL(msg)

  #define LOGI_SYS_IMPL(msg)   Serial.println(F("[INFO][SYS] " msg))
  #define LOGI_SD_IMPL(msg)    Serial.println(F("[INFO][SD] " msg))
  #define LOGI_DIR_IMPL(msg)   Serial.println(F("[INFO][DIR] " msg))
  #define LOGI_FILE_IMPL(msg)  ((void)0)
  #define LOGI_PRG_IMPL(msg)   ((void)0)
  #define LOGI_PROTO_IMPL(msg) ((void)0)
  #define LOGI_ERR_IMPL(msg)   ((void)0)
  #define LOGI(cat, msg)       LOGI_##cat##_IMPL(msg)

  #define LOG_PRINT(x)         Serial.print(x)
  #define LOG_PRINTLN(x)       Serial.println(x)
  #define LOG_PRINT_F(msg)     Serial.print(F(msg))
  #define LOG_PRINTLN_F(msg)   Serial.println(F(msg))
  #define LOG_HEX(x)           Serial.print(x, HEX)
  #define LOG_DEC(x)           Serial.print(x, DEC)
  #define LOG_NEWLINE()        Serial.println()

#else
  //----------------------------------------------------------------------------
  // RELEASE BUILD (silent) — zero overhead
  //----------------------------------------------------------------------------
  #define LOG_BEGIN(baud)       ((void)0)
  #define LOGE(cat, msg)        ((void)0)
  #define LOGI(cat, msg)        ((void)0)
  #define LOG_PRINT(x)          ((void)0)
  #define LOG_PRINTLN(x)        ((void)0)
  #define LOG_PRINT_F(msg)      ((void)0)
  #define LOG_PRINTLN_F(msg)    ((void)0)
  #define LOG_HEX(x)            ((void)0)
  #define LOG_DEC(x)            ((void)0)
  #define LOG_NEWLINE()         ((void)0)

#endif // EASYSD_DEBUG_SERIAL

#endif // _EASYSDLOG_H
