@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

IF "%DEBUG%"=="" SET DEBUG=0
IF "%DEBUG_BREAK_AFTER_LOAD%"=="" SET DEBUG_BREAK_AFTER_LOAD=0
IF "%BUILD_ARDUINO%"=="" SET BUILD_ARDUINO=1

IF "%MENU_PRG_NAME%"=="" (
  IF "%DEBUG%"=="1" (SET "MENU_PRG_NAME=irqhack64-debug.prg") ELSE (SET "MENU_PRG_NAME=irqhack64.prg")
)

SET "PROJECT_DIR=%~dp0"
FOR %%I IN ("%PROJECT_DIR%..\..") DO SET "REPO_ROOT=%%~fI"
SET "TOOLS_DIR=%REPO_ROOT%\tools"

PUSHD "%PROJECT_DIR%" >NUL

IF NOT EXIST build mkdir build
IF NOT EXIST build\symbol mkdir build\symbol
IF NOT EXIST build\listing mkdir build\listing
IF NOT EXIST build\plugins mkdir build\plugins

ECHO ==============================================================
ECHO [CORE] Building core
ECHO   PROJECT_DIR=%PROJECT_DIR%
ECHO   REPO_ROOT=%REPO_ROOT%
ECHO   DEBUG=%DEBUG%
ECHO   BUILD_ARDUINO=%BUILD_ARDUINO%
ECHO   MENU_PRG_NAME=%MENU_PRG_NAME%
ECHO ==============================================================

CALL PreBuild.bat
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

ECHO [CORE] petcat: Menus\EasySD\IrqLoaderMenu.bas
petcat -w2 <Menus\EasySD\IrqLoaderMenu.bas >build\IrqLoaderMenu.obj
IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

ECHO [CORE] 64tass: Menus\EasySD\IrqLoaderMenuNew.s
PUSHD Menus\EasySD >NUL
64tass -c -b --long-branch -D DEBUG=%DEBUG% -D DEBUG_BREAK_AFTER_LOAD=%DEBUG_BREAK_AFTER_LOAD% IrqLoaderMenuNew.s ^
  -o ..\..\build\IrqLoaderMenuNew.bin --labels ..\..\build\symbol\IrqLoaderMenuNew.txt -L ..\..\build\listing\IrqLoaderMenuNewLst.txt
SET "RC=%ERRORLEVEL%"
POPD >NUL
IF NOT "%RC%"=="0" (POPD >NUL & EXIT /B %RC%)

ECHO [CORE] link: build\%MENU_PRG_NAME%
copy /b build\IrqLoaderMenu.obj + build\IrqLoaderMenuNew.bin build\%MENU_PRG_NAME% >NUL
SET "RC=%ERRORLEVEL%"
IF NOT "%RC%"=="0" (POPD >NUL & EXIT /B %RC%)
del build\IrqLoaderMenuNew.bin >NUL 2>NUL

IF "%BUILD_ARDUINO%"=="1" (
  ECHO [CORE] 64tass: Loader\LoaderStub.65s
  64tass -c -b Loader\LoaderStub.65s -o build\LoaderStub.65s.bin --labels build\symbol\LoaderStub.65s.txt
  IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)

  ECHO [CORE] 64tass: Loader\IRQLoader.65s
  64tass -c -b Loader\IRQLoader.65s -o build\IRQLoader.65s.bin --labels build\symbol\IRQLoader.txt
  IF %ERRORLEVEL% NEQ 0 (POPD >NUL & EXIT /B %ERRORLEVEL%)
)

IF NOT EXIST build\IrqLoaderMenu.obj (
  ECHO.
  echo ERROR: Missing build\IrqLoaderMenu.obj ^(required by plugin PRG prefix concat^).
  ECHO.
  POPD >NUL
  EXIT /B 1
)

ECHO [CORE] OK
POPD >NUL
EXIT /B 0
