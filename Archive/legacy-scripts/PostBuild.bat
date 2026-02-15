@echo off
setlocal ENABLEEXTENSIONS

REM --- normalize script directory (no trailing backslash) ---
for %%I in ("%~dp0.") do set "PROJECT_DIR=%%~fI"

REM --- repo_root is ONE level up ---
for %%I in ("%PROJECT_DIR%\..") do set "REPO_ROOT=%%~fI"

set "TOOLS_DIR=%REPO_ROOT%\tools"
set "ARDUINO_IRQHACK_DIR=%REPO_ROOT%\Arduino\IRQHack64"

pushd "%PROJECT_DIR%" >NUL

ECHO ==============================================================
ECHO [POST] Building Arduino headers + EPROM image
ECHO   TOOLS_DIR=%TOOLS_DIR%
ECHO   ARDUINO_IRQHACK_DIR=%ARDUINO_IRQHACK_DIR%
ECHO ==============================================================

if not exist "%TOOLS_DIR%\Bin2ArdH.exe" (
  echo.
  echo ERROR: Missing tool: "%TOOLS_DIR%\Bin2ArdH.exe"
  echo        Check repo_root\Tools\
  echo.
  popd 
  exit /b 1
)

if not exist "%TOOLS_DIR%\CreateEpromLoader.exe" (
  echo.
  echo ERROR: Missing tool: "%TOOLS_DIR%\CreateEpromLoader.exe"
  echo.
  popd >NUL
  exit /b 1
)

if not exist "%ARDUINO_IRQHACK_DIR%" (
  echo.
  echo ERROR: Missing Arduino target dir: "%ARDUINO_IRQHACK_DIR%"
  echo.
  popd >NUL
  exit /b 1
)

64tass -c -b Menus\WarningMenu\Warning.s -o build\Warning.bin --labels build\symbol\Warning.s.txt
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

copy /b build\IrqLoaderMenu.obj + build\Warning.bin build\warning.prg >NUL
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)
del build\Warning.bin >NUL 2>NUL

"%TOOLS_DIR%\Bin2ArdH.exe" build\warning.prg build\defaultmenu.h data_len cartridgeData
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

"%TOOLS_DIR%\Bin2ArdH.exe" build\LoaderStub.65s.bin build\LoaderStub.h stub_len stubData
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

copy avrincludehead.txt + build\defaultmenu.h build\head.tmp >NUL
copy build\head.tmp + build\LoaderStub.h build\final.tmp >NUL
copy build\final.tmp + avrincludefoot.txt build\FlashLib.h >NUL

copy build\FlashLib.h "%ARDUINO_IRQHACK_DIR%\FlashLib.h" >NUL

"%TOOLS_DIR%\CreateEpromLoader.exe" build\IRQLoader.65s.bin build\IRQLoaderRom.bin 171 166 103 141 121 151 146 161 156 195 176 255
ECHO.
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

del build\defaultmenu.h >NUL 2>NUL
del build\LoaderStub.h >NUL 2>NUL
del build\head.tmp >NUL 2>NUL
del build\final.tmp >NUL 2>NUL

ECHO [POST] OK
POPD >NUL
EXIT /B 0
