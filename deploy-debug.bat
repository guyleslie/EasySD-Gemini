@echo off
REM Arduino debug deploy: C64 debug build + ISP upload (serial ON) + SD card update
REM Usage: deploy-debug.bat
setlocal

set "STEP1=NOT RUN"
set "STEP2=NOT RUN"
set "STEP3=NOT RUN"
set "FAILED_STEP="

echo ==============================
echo  EasySD Debug Deploy (Arduino)
echo ==============================
echo.

echo [1/3] C64 debug build + FlashLib.h (serial ON)...
python Tools/build.py debug-arduino
if errorlevel 1 (
    set "STEP1=FAIL"
    set "FAILED_STEP=debug-arduino build"
    goto :summary_fail
)
set "STEP1=OK"

echo.
echo [2/3] Arduino compile + ISP upload (debug)...
python Tools/build.py arduino-upload-isp --debug
if errorlevel 1 (
    set "STEP2=FAIL"
    set "FAILED_STEP=ISP upload"
    goto :summary_fail
)
set "STEP2=OK"

echo.
echo [3/3] SD card deploy (D:, debug menu)...
python Tools/build.py sd-deploy D: --debug
if errorlevel 1 (
    set "STEP3=FAIL"
    set "FAILED_STEP=SD deploy"
    goto :summary_fail
)
set "STEP3=OK"

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
call :print_step "Debug build" "%STEP1%"
call :print_step "ISP upload" "%STEP2%"
call :print_step "SD deploy" "%STEP3%"
powershell -NoProfile -Command "Write-Host ''; Write-Host 'DEBUG DEPLOY COMPLETE' -ForegroundColor Green; Write-Host 'Serial: 57600 baud, h=help' -ForegroundColor Green"
pause
exit /b 0

:summary_fail
echo.
echo ==============================
echo  Final summary
echo ==============================
call :print_step "Debug build" "%STEP1%"
call :print_step "ISP upload" "%STEP2%"
call :print_step "SD deploy" "%STEP3%"
powershell -NoProfile -Command "Write-Host ''; Write-Host 'DEBUG DEPLOY FAILED: %FAILED_STEP%' -ForegroundColor Red"
pause
exit /b 1
