@echo off
setlocal ENABLEEXTENSIONS

REM =============================================================================
REM EasySD include discipline checks (fail fast)
REM This script MUST live in the project folder that contains:
REM   Loader\  Menus\  Plugins\  build\
REM =============================================================================

pushd "%~dp0" >NUL

set "_PAT_ZPMAP=^[ 	]*\.include[ 	][ 	]*.*CartZpMap\.inc"
set "_PAT_CL_COMMON=^[ 	]*\.include[ 	][ 	]*.*CartLibCommon\.s"
%_CNT_ZPMAP% = 1


call :COUNT "%_PAT_ZPMAP%" "*.s *.inc" _CNT_ZPMAP
call :COUNT "%_PAT_ZPMAP%" "Loader\CartLibStream.s" _CNT_ZPMAP_STREAM
call :COUNT "%_PAT_CL_COMMON%" "*.s *.inc" _CNT_CL_COMMON
call :COUNT "%_PAT_CL_COMMON%" "Loader\CartLib.s" _CNT_CL_COMMON_ROOT
call :COUNT "%_PAT_ZPMAP%" "Plugins\*.s Plugins\*.inc" _CNT_PLUGIN_ZPMAP
call :COUNT "%_PAT_CL_COMMON%" "Plugins\*.s Plugins\*.inc" _CNT_PLUGIN_CL_COMMON

if not "%_CNT_ZPMAP%"=="1" (
  echo.
  echo ERROR: CartZpMap.inc include count is %_CNT_ZPMAP% ^(expected: 1^)
  echo        Fix the include chain. Do not add include-guards.
  echo.
  popd >NUL
  exit /b 1
)
if not "%_CNT_ZPMAP_STREAM%"=="1" (
  echo.
  echo ERROR: CartZpMap.inc must be included from Loader\CartLibStream.s ^(expected: 1 match there^)
  echo        Found %_CNT_ZPMAP_STREAM% matches in Loader\CartLibStream.s.
  echo.
  popd >NUL
  exit /b 1
)

if not "%_CNT_CL_COMMON%"=="1" (
  echo.
  echo ERROR: CartLibCommon.s include count is %_CNT_CL_COMMON% ^(expected: 1^)
  echo        Fix the include chain. Do not add include-guards.
  echo.
  popd >NUL
  exit /b 1
)
if not "%_CNT_CL_COMMON_ROOT%"=="1" (
  echo.
  echo ERROR: CartLibCommon.s must be included from Loader\CartLib.s ^(expected: 1 match there^)
  echo        Found %_CNT_CL_COMMON_ROOT% matches in Loader\CartLib.s.
  echo.
  popd >NUL
  exit /b 1
)

if not "%_CNT_PLUGIN_ZPMAP%"=="0" (
  echo.
  echo ERROR: Plugins must NOT include CartZpMap.inc directly. Found %_CNT_PLUGIN_ZPMAP% matches.
  echo        Include Loader\CartLibStream.s ^(or the public wrapper^) instead.
  echo.
  popd >NUL
  exit /b 1
)
if not "%_CNT_PLUGIN_CL_COMMON%"=="0" (
  echo.
  echo ERROR: Plugins must NOT include CartLibCommon.s directly. Found %_CNT_PLUGIN_CL_COMMON% matches.
  echo        Include Loader\CartLib.s ^(or a higher-level CartLib include^) instead.
  echo.
  popd >NUL
  exit /b 1
)

popd >NUL
exit /b 0

:COUNT
REM %1=pattern, %2=filespec(s), %3=outvar
setlocal
set "PAT=%~1"
set "FILES=%~2"
set "CNT=0"
for /f %%A in ('findstr /S /I /R /C:"%PAT%" %FILES% 2^>NUL ^| find /C /V ""') do set "CNT=%%A"
endlocal & set "%~3=%CNT%"
exit /b 0
