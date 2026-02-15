@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

IF "%DEBUG%"=="" SET DEBUG=0
IF "%DEBUG_BREAK_AFTER_LOAD%"=="" SET DEBUG_BREAK_AFTER_LOAD=0

IF NOT EXIST ..\..\build\plugins\NUL  mkdir ..\..\build\plugins >NUL 2>NUL
IF NOT EXIST ..\..\build\symbol\NUL   mkdir ..\..\build\symbol >NUL 2>NUL
IF NOT EXIST ..\..\build\listing\NUL  mkdir ..\..\build\listing >NUL 2>NUL

ECHO [PLUGIN] 64tass: BurstLoader.s  (DEBUG=%DEBUG%)
64tass -c -b -D DEBUG=%DEBUG% -D DEBUG_BREAK_AFTER_LOAD=%DEBUG_BREAK_AFTER_LOAD% "BurstLoader.s" ^
  -o ..\..\build\plugins\cvidplugin.bin ^
  --labels ..\..\build\symbol\BurstLoader.txt ^
  -L ..\..\build\listing\BurstLoaderLST.txt
IF NOT "!ERRORLEVEL!"=="0" EXIT /B !ERRORLEVEL!

REM Plugin PRG = BASIC prefix (IrqLoaderMenu.obj) + plugin binary
copy /b ..\..\build\IrqLoaderMenu.obj + ..\..\build\plugins\cvidplugin.bin ..\..\build\plugins\cvidplugin.prg >NUL
SET "RC=%ERRORLEVEL%"
DEL ..\..\build\plugins\cvidplugin.bin >NUL 2>NUL

EXIT /B %RC%
