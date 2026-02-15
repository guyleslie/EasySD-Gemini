@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

IF "%DEBUG%"=="" SET DEBUG=0
IF "%DEBUG_BREAK_AFTER_LOAD%"=="" SET DEBUG_BREAK_AFTER_LOAD=0

PUSHD "%~dp0" >NUL

IF NOT EXIST build mkdir build
IF NOT EXIST build\plugins mkdir build\plugins
IF NOT EXIST build\symbol mkdir build\symbol
IF NOT EXIST build\listing mkdir build\listing

ECHO ==============================================================
ECHO [PLUGINS] Building all plugins
ECHO   DEBUG=%DEBUG%
ECHO   DEBUG_BREAK_AFTER_LOAD=%DEBUG_BREAK_AFTER_LOAD%
ECHO ==============================================================

IF NOT EXIST build\IrqLoaderMenu.obj (
  ECHO [PLUGINS] Missing build\IrqLoaderMenu.obj - building core prereqs first...
  SET BUILD_ARDUINO=0
  CALL build_core.bat
  IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)
)

CALL :BUILD_ONE BurstLoader cvidplugin.prg || GOTO FAIL
CALL :BUILD_ONE KoalaDisplayer koaplugin.prg || GOTO FAIL
CALL :BUILD_ONE PetsciiDisplayer petgplugin.prg || GOTO FAIL
CALL :BUILD_ONE PrgPlugin prgplugin.prg || GOTO FAIL
CALL :BUILD_ONE WavPlayer wavplugin.prg || GOTO FAIL
CALL :BUILD_ONE MusPlayer musplugin.prg || GOTO FAIL

ECHO [PLUGINS] OK
POPD >NUL
EXIT /B 0

:BUILD_ONE
SET "PLUGIN_DIR=%~1"
SET "PLUGIN_OUT=%~2"
ECHO   - %PLUGIN_DIR% -> build\plugins\%PLUGIN_OUT%
PUSHD "Plugins\%PLUGIN_DIR%" >NUL
CALL compile.bat
SET "RC=%ERRORLEVEL%"
POPD >NUL
IF NOT "%RC%"=="0" (
  ECHO ERROR: %PLUGIN_DIR% build failed (code %RC%)
  EXIT /B %RC%
)
EXIT /B 0

:FAIL
SET "RC=%ERRORLEVEL%"
ECHO ERROR: Plugin build chain failed (code %RC%)
POPD >NUL
EXIT /B %RC%
