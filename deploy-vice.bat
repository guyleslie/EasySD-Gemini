@echo off
REM VICE emulator debug build (C64 only, no Arduino)
REM Usage: deploy-vice.bat

echo ==============================
echo  EasySD VICE Debug Build
echo ==============================
echo.

echo Building C64 debug (VICE mock data)...
python Tools/build.py debug-vice
if errorlevel 1 (
    echo FAILED: debug-vice build
    pause
    exit /b 1
)

echo.
echo ==============================
echo  VICE build complete!
echo.
echo  Load in VICE:
echo    x64sc build\easysd-debug.prg
echo.
echo  Run automated tests:
echo    python Tools/test_vice_menu.py --verbose
echo ==============================
pause
