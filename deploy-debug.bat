@echo off
REM Arduino serial debug deploy: full RELEASE artifact refresh + Arduino DEBUG firmware (serial ON) + SD card update.
REM Use this to test real hardware with Arduino serial logging enabled while running
REM the release C64 software (EASYSD.PRG from SD card, not the debug C64 build).
REM Usage: deploy-debug.bat
setlocal

set "STEP1=NOT RUN"
set "STEP2=NOT RUN"
set "STEP3=NOT RUN"
set "FAILED_STEP="

echo ==============================
echo  EasySD Arduino Debug Deploy
echo  (C64 release + Arduino serial)
echo ==============================
echo.

echo [1/3] Fresh release build (refresh C64, SD bundle, and generated Arduino blobs)...
python Tools/build.py release
if errorlevel 1 (
    set "STEP1=FAIL"
    set "FAILED_STEP=Release artifact refresh"
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
echo [3/3] SD card deploy (D:, release content)...
python Tools/build.py sd-deploy D:
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
call :print_step "Release artifact refresh" "%STEP1%"
call :print_step "ISP upload" "%STEP2%"
call :print_step "SD deploy" "%STEP3%"
powershell -NoProfile -Command "Write-Host ''; Write-Host 'DEBUG DEPLOY COMPLETE' -ForegroundColor Green; Write-Host 'Serial monitor: python Tools/build.py arduino-monitor COM4' -ForegroundColor Cyan"
pause
exit /b 0

:summary_fail
echo.
echo ==============================
echo  Final summary
echo ==============================
call :print_step "Release artifact refresh" "%STEP1%"
call :print_step "ISP upload" "%STEP2%"
call :print_step "SD deploy" "%STEP3%"
powershell -NoProfile -Command "Write-Host ''; Write-Host 'DEBUG DEPLOY FAILED: %FAILED_STEP%' -ForegroundColor Red"
pause
exit /b 1
