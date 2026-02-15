@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

SET DEBUG=1
SET DEBUG_BREAK_AFTER_LOAD=0
SET BUILD_ARDUINO=1
SET "MENU_PRG_NAME=irqhack64-debug.prg"

PUSHD "%~dp0" >NUL

ECHO ==============================================================
ECHO EasySD BUILD (DEBUG)
ECHO   DEBUG=%DEBUG%
ECHO   BUILD_ARDUINO=%BUILD_ARDUINO%
ECHO ==============================================================

CALL Clean.bat || GOTO FAIL
CALL PreBuild.bat || GOTO FAIL
CALL build_core.bat || GOTO FAIL
CALL build_plugins_all.bat || GOTO FAIL

ECHO ==============================================================
ECHO BUILD SUCCESSFUL (DEBUG)
ECHO Output: build\%MENU_PRG_NAME%  + build\plugins\*.prg
ECHO ==============================================================

POPD >NUL
EXIT /B 0

:FAIL
SET "RC=%ERRORLEVEL%"
ECHO ==============================================================
ECHO BUILD FAILED (DEBUG) - code %RC%
ECHO ==============================================================
POPD >NUL
EXIT /B %RC%
