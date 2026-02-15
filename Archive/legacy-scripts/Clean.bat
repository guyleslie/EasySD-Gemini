@ECHO OFF
SETLOCAL

PUSHD "%~dp0" >NUL
ECHO [CLEAN] Removing build artifacts...

IF EXIST build (
  del /q build\*.prg 2>NUL
  del /q build\*.bin 2>NUL
  del /q build\*.obj 2>NUL
)

IF EXIST build\plugins (
  del /q build\plugins\*.prg 2>NUL
  del /q build\plugins\*.bin 2>NUL
)

IF EXIST build\listing del /q build\listing\*.* 2>NUL
IF EXIST build\symbol del /q build\symbol\*.* 2>NUL

ECHO [CLEAN] Done.
POPD >NUL
EXIT /B 0
