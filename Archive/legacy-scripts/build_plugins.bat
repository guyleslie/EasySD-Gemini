@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

REM =============================================================================
REM [PLUGINS] Build all plugins.
REM Requires: build\IrqLoaderMenu.obj exists (plugin PRG prefix).
REM If missing, builds core prereqs automatically (BUILD_ARDUINO forced 0).
REM =============================================================================

PUSHD "%~dp0" >NUL

IF NOT EXIST build\IrqLoaderMenu.obj (
  ECHO [PLUGINS] Missing build\IrqLoaderMenu.obj - building core prereqs first...
  SET BUILD_ARDUINO=0
  SET "MENU_PRG_NAME=irqhack64.prg"
  CALL build_core.bat
  IF NOT "!ERRORLEVEL!"=="0" (POPD >NUL & EXIT /B !ERRORLEVEL!)
)

ECHO ==============================================================
ECHO [PLUGINS] Building all plugins
ECHO   DEBUG=%DEBUG%
ECHO   DEBUG_BREAK_AFTER_LOAD=%DEBUG_BREAK_AFTER_LOAD%
ECHO ==============================================================

CALL build_plugins_all.bat
SET "RC=%ERRORLEVEL%"
IF NOT "%RC%"=="0" (
  ECHO [PLUGINS] FAILED (code %RC%)
  POPD >NUL
  EXIT /B %RC%
)

ECHO [PLUGINS] OK
POPD >NUL
EXIT /B 0
