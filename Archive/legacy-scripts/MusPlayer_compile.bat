@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

IF "%DEBUG%"=="" SET DEBUG=0
IF "%DEBUG_BREAK_AFTER_LOAD%"=="" SET DEBUG_BREAK_AFTER_LOAD=0

IF NOT EXIST ..\..\build\plugins\NUL  mkdir ..\..\build\plugins >NUL 2>NUL
IF NOT EXIST ..\..\build\symbol\NUL   mkdir ..\..\build\symbol >NUL 2>NUL
IF NOT EXIST ..\..\build\listing\NUL  mkdir ..\..\build\listing >NUL 2>NUL

ECHO [PLUGIN] 64tass: MusPlayer.s  (DEBUG=%DEBUG%)
64tass -c -b -D DEBUG=%DEBUG% -D DEBUG_BREAK_AFTER_LOAD=%DEBUG_BREAK_AFTER_LOAD% "MusPlayer.s" ^
  -o ..\..\build\plugins\musplugin.bin ^
  --labels ..\..\build\symbol\musplugin.txt ^
  -L ..\..\build\listing\muspluginLST.txt
IF NOT "!ERRORLEVEL!"=="0" EXIT /B !ERRORLEVEL!

REM Plugin PRG = BASIC prefix (IrqLoaderMenu.obj) + plugin binary
copy /b ..\..\build\IrqLoaderMenu.obj + ..\..\build\plugins\musplugin.bin ..\..\build\plugins\musplugin.prg >NUL
copy ..\..\..\Tools\ComputeSidPlayer.prg ..\..\build\plugins\sidplayer.prg >NUL
SET "RC=%ERRORLEVEL%"
DEL ..\..\build\plugins\musplugin.bin >NUL 2>NUL

EXIT /B %RC%
