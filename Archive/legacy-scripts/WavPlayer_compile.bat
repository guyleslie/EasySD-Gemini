@ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

IF "%DEBUG%"=="" SET DEBUG=0
IF "%DEBUG_BREAK_AFTER_LOAD%"=="" SET DEBUG_BREAK_AFTER_LOAD=0

IF NOT EXIST ..\..\build\plugins\NUL  mkdir ..\..\build\plugins >NUL 2>NUL
IF NOT EXIST ..\..\build\symbol\NUL   mkdir ..\..\build\symbol >NUL 2>NUL
IF NOT EXIST ..\..\build\listing\NUL  mkdir ..\..\build\listing >NUL 2>NUL

ECHO [PLUGIN] 64tass: WavPlayer.s  (DEBUG=%DEBUG%)
64tass -c -b -D DEBUG=%DEBUG% -D DEBUG_BREAK_AFTER_LOAD=%DEBUG_BREAK_AFTER_LOAD% "WavPlayer.s" ^
  -o ..\..\build\plugins\wavplugin.bin ^
  --labels ..\..\build\symbol\wavplugin.txt ^
  -L ..\..\build\listing\wavpluginLST.txt
IF NOT "!ERRORLEVEL!"=="0" EXIT /B !ERRORLEVEL!

REM Plugin PRG = BASIC prefix (IrqLoaderMenu.obj) + plugin binary
copy /b ..\..\build\IrqLoaderMenu.obj + ..\..\build\plugins\wavplugin.bin ..\..\build\plugins\wavplugin.prg >NUL
SET "RC=%ERRORLEVEL%"
DEL ..\..\build\plugins\wavplugin.bin >NUL 2>NUL

EXIT /B %RC%
