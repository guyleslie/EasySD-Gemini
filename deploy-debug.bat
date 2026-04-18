@echo off
REM Arduino debug deploy: C64 debug build + ISP upload (serial ON) + SD card update
REM Usage: deploy-debug.bat

echo ==============================
echo  EasySD Debug Deploy (Arduino)
echo ==============================
echo.

echo [1/3] C64 debug build + FlashLib.h (serial ON)...
python Tools/build.py debug-arduino
if errorlevel 1 (
    echo FAILED: debug-arduino build
    pause
    exit /b 1
)

echo.
echo [2/3] Arduino compile + ISP upload (debug)...
python Tools/build.py arduino-upload-isp --debug
if errorlevel 1 (
    echo FAILED: ISP upload
    pause
    exit /b 1
)

echo.
echo [3/3] SD card deploy (D:, debug menu)...
python Tools/build.py sd-deploy D: --debug
if errorlevel 1 (
    echo FAILED: SD deploy
    pause
    exit /b 1
)

echo.
echo ==============================
echo  Debug deploy complete!
echo  Serial: 57600 baud, h=help
echo ==============================
pause
