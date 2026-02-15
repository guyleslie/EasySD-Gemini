@echo off
setlocal ENABLEEXTENSIONS

REM =============================================================================
REM EasySD include discipline checks (fail fast)
REM =============================================================================

REM Always run relative to this script's directory (repo root)
pushd "%~dp0" >NUL

REM Initialize counters (prevents empty vars when no matches are found)
set "_CNT_ZPMAP=0"
set "_CNT_ZPMAP_STREAM=0"
set "_CNT_CL_COMMON=0"
set "_CNT_CL_COMMON_ROOT=0"
set "_CNT_PLUGIN_ZPMAP=0"
set "_CNT_PLUGIN_CL_COMMON=0"

REM -----------------------------------------------------------------------------
REM findstr regex notes:
REM - findstr uses a limited regex dialect (no '+' quantifier).
REM - Allow both spaces and tabs before directives.
REM -----------------------------------------------------------------------------

REM ==== CartZpMap.inc must be included exactly once, and only from Loader\CartLibStream.s ====
REM Match: optional whitespace + .include + anything + CartZpMap.inc
set "_PAT_ZPMAP=^[ 	]*\.include[ 	][ 	]*.*CartZpMap\.inc"

for /f %%A in ('findstr /S /I /R /C:"%_PAT_ZPMAP%" *.s *.inc 2^>NUL ^| find /C /V ""') do set "_CNT_ZPMAP=%%A"
for /f %%A in ('findstr /I /R /C:"%_PAT_ZPMAP%" Loader\CartLibStream.s 2^>NUL ^| find /C /V ""') do set "_CNT_ZPMAP_STREAM=%%A"

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

REM ==== CartLibCommon.s must be included exactly once, and only from Loader\CartLib.s ====
set "_PAT_CL_COMMON=^[ 	]*\.include[ 	][ 	]*.*CartLibCommon\.s"

for /f %%A in ('findstr /S /I /R /C:"%_PAT_CL_COMMON%" *.s *.inc 2^>NUL ^| find /C /V ""') do set "_CNT_CL_COMMON=%%A"
for /f %%A in ('findstr /I /R /C:"%_PAT_CL_COMMON%" Loader\CartLib.s 2^>NUL ^| find /C /V ""') do set "_CNT_CL_COMMON_ROOT=%%A"

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

REM ==== Plugins must NOT include core low-level includes directly ====
for /f %%A in ('findstr /S /I /R /C:"%_PAT_ZPMAP%" Plugins\*.s Plugins\*.inc 2^>NUL ^| find /C /V ""') do set "_CNT_PLUGIN_ZPMAP=%%A"
if not "%_CNT_PLUGIN_ZPMAP%"=="0" (
  echo.
  echo ERROR: Plugins must NOT include CartZpMap.inc directly. Found %_CNT_PLUGIN_ZPMAP% matches.
  echo        Include Loader\CartLibStream.s ^(or the public wrapper^) instead.
  echo.
  popd >NUL
  exit /b 1
)

for /f %%A in ('findstr /S /I /R /C:"%_PAT_CL_COMMON%" Plugins\*.s Plugins\*.inc 2^>NUL ^| find /C /V ""') do set "_CNT_PLUGIN_CL_COMMON=%%A"
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
