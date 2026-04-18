@echo off
REM VICE emulator debug build (C64 only, no Arduino)
REM Usage: deploy-vice.bat
setlocal

set "STEP1=NOT RUN"
set "FAILED_STEP="

echo ==============================
echo  EasySD VICE Debug Build
echo ==============================
echo.

echo Building C64 debug (VICE mock data)...
python Tools/build.py debug-vice
if errorlevel 1 (
    set "STEP1=FAIL"
    set "FAILED_STEP=debug-vice build"
    goto :summary_fail
)
set "STEP1=OK"

echo.
goto :summary_ok

:print_step
set "STEP_LABEL=%~1"
set "STEP_STATE=%~2"
if /I "%STEP_STATE%"=="OK" (
    powershell -NoProfile -Command "Write-Host '[OK]   %STEP_LABEL%' -ForegroundColor Green"
    exit /b 0
)
if /I "%STEP_STATE%"=="FAIL" (
    powershell -NoProfile -Command "Write-Host '[FAIL] %STEP_LABEL%' -ForegroundColor Red"
    exit /b 0
)
powershell -NoProfile -Command "Write-Host '[----] %STEP_LABEL%' -ForegroundColor DarkGray"
exit /b 0

:summary_ok
echo.
echo ==============================
echo  Final summary
echo ==============================
call :print_step "VICE debug build" "%STEP1%"
powershell -NoProfile -Command "Write-Host ''; Write-Host 'VICE BUILD COMPLETE' -ForegroundColor Green"
echo.
echo Load in VICE:
echo   x64sc build\easysd-debug.prg
echo.
echo Run automated tests:
echo   python Tools/test_vice_menu.py --verbose
pause
exit /b 0

:summary_fail
echo.
echo ==============================
echo  Final summary
echo ==============================
call :print_step "VICE debug build" "%STEP1%"
powershell -NoProfile -Command "Write-Host ''; Write-Host 'VICE BUILD FAILED: %FAILED_STEP%' -ForegroundColor Red"
pause
exit /b 1
